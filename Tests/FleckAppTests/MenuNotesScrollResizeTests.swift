import AppKit
import FleckCore
import Foundation
import SwiftUI
import Testing

@testable import FleckApp

// Hosted scroll control for ELV-106.
//
// Drives the real `NotesPanel` hierarchy and reaches both horizontal SwiftUI
// `ScrollView`s it owns: the note tab strip and the folder strip. It observes
// only app-owned state (view geometry, the panel's own accessibility elements,
// workspace selection) plus public AppKit. No global input, no system
// accessibility API, no other process windows.
//
// Content: 3 titles capped at 160pt (~576pt of tab strip content) and 5 short
// folder chips. The container test measures both overflow crossings from the
// app itself and derives its widths from them, so the tab-only state is proved
// rather than assumed. The stored panel narrows to 480 (both strips must
// overflow) and widens to 1040 (both must fit) before a real release.

private let menuScrollTabRail: CGFloat = 56
private let menuScrollFolderRail: CGFloat = 56

@MainActor
private func menuScrollWideNotes(count: Int) -> [Note] {
  (0..<count).map { index in
    Note(
      title: "Synthetic note \(index) " + String(repeating: "wide title ", count: 5),
      body: "Synthetic body \(index)\n" + String(repeating: "A wrapped synthetic line. ", count: 24)
    )
  }
}

@MainActor
private func menuScrollShortFolders(count: Int) throws -> [Folder] {
  try (0..<count).map { index in
    try Folder(name: "Folder \(index)")
  }
}

// MARK: - App-owned accessibility traversal

@MainActor
private func menuScrollElement(_ value: Any?, label: String) -> NSObject? {
  guard let element = value as? NSObject else { return nil }
  let labelSelector = NSSelectorFromString("accessibilityLabel")
  let childrenSelector = NSSelectorFromString("accessibilityChildren")
  let name =
    element.responds(to: labelSelector)
    ? element.perform(labelSelector)?.takeUnretainedValue() as? String : nil
  if name == label { return element }
  let children =
    element.responds(to: childrenSelector)
    ? element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] : nil
  for child in children ?? [] {
    if let found = menuScrollElement(child, label: label) { return found }
  }
  return nil
}

@MainActor
private func menuScrollElement(_ value: Any?, identifier: String) -> NSObject? {
  guard let element = value as? NSObject else { return nil }
  let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
  let childrenSelector = NSSelectorFromString("accessibilityChildren")
  let name =
    element.responds(to: identifierSelector)
    ? element.perform(identifierSelector)?.takeUnretainedValue() as? String : nil
  if name == identifier { return element }
  let children =
    element.responds(to: childrenSelector)
    ? element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] : nil
  for child in children ?? [] {
    if let found = menuScrollElement(child, identifier: identifier) { return found }
  }
  return nil
}

@MainActor
private func menuScrollAccessibilityLabel(_ element: NSObject?) -> String? {
  guard let element else { return nil }
  let selector = NSSelectorFromString("accessibilityLabel")
  guard element.responds(to: selector) else { return nil }
  return element.perform(selector)?.takeUnretainedValue() as? String
}

@MainActor
private func menuScrollPress(_ element: NSObject) -> Bool {
  let selector = NSSelectorFromString("accessibilityPerformPress")
  guard element.responds(to: selector) else { return false }
  _ = element.perform(selector)
  return true
}

// MARK: - View traversal, settling, local events

@MainActor
private func menuScrollDescendants<T: NSView>(in view: NSView, as type: T.Type) -> [T] {
  var matches: [T] = []
  if let match = view as? T { matches.append(match) }
  for child in view.subviews {
    matches.append(contentsOf: menuScrollDescendants(in: child, as: type))
  }
  return matches
}

@MainActor
private func menuScrollTabScrollView(in host: NSView) -> NSScrollView? {
  menuScrollDescendants(in: host, as: FluidTabDestinationView.self).first?.enclosingScrollView
}

@MainActor
private func menuScrollFolderScrollView(in host: NSView) throws -> NSScrollView {
  let trash = try #require(
    menuScrollElement(host, identifier: "folder-trash"),
    "The folder navigator must publish its trash row to the app accessibility tree"
  )
  let trashFrame = try #require(
    trash.value(forKey: "accessibilityFrame") as? NSValue
  ).rectValue
  let hostWindow = try #require(host.window)
  return try #require(
    menuScrollDescendants(in: host, as: NSScrollView.self)
      .filter { scroll in
        let screenFrame = hostWindow.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        return screenFrame.minY <= trashFrame.midY && screenFrame.maxY >= trashFrame.midY
          && screenFrame.height <= 34
      }
      .min { $0.bounds.height < $1.bounds.height },
    "The folder strip must host its horizontal scroll view on the navigator row"
  )
}

@MainActor
private func menuScrollDrainMainQueue() async {
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    DispatchQueue.main.async { continuation.resume() }
  }
}

@MainActor
private func menuScrollSettle(_ host: NSView) async {
  for _ in 0..<40 {
    host.layoutSubtreeIfNeeded()
    await Task.yield()
  }
  await menuScrollDrainMainQueue()
  await menuScrollDrainMainQueue()
  for _ in 0..<8 {
    host.layoutSubtreeIfNeeded()
    await Task.yield()
  }
}

@MainActor
private func menuScrollSendMouse(
  _ type: NSEvent.EventType,
  at location: CGPoint,
  in window: NSWindow,
  number: Int
) {
  guard
    let event = NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: number,
      clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    )
  else {
    Issue.record("Could not create local \(type) event")
    return
  }
  NSApplication.shared.sendEvent(event)
}

@MainActor
private func menuScrollSendMouse(
  _ type: NSEvent.EventType,
  atScreen location: CGPoint,
  in window: NSWindow,
  number: Int
) {
  menuScrollSendMouse(
    type,
    at: window.convertPoint(fromScreen: location),
    in: window,
    number: number
  )
}

// MARK: - Shared hosted fixture

private enum MenuScrollSizing: Equatable {
  case container
  case storedPreferences
}

@MainActor
private final class MenuNotesScrollFixture {
  let root: URL
  let notes: [Note]
  let folders: [Folder]
  let state: AppState
  let runtime: DictationRuntime
  let host: NSHostingView<AnyView>
  let window: NSWindow
  private var status: MenuScrollStatusButtonFixture?
  private let previousAccessibilityValue: Any?

  init(
    width: CGFloat,
    height: CGFloat = 430,
    sizing: MenuScrollSizing,
    statusButtonFrame: CGRect? = nil,
    panelWidth: CGFloat? = nil,
    panelHeight: CGFloat? = nil
  ) async throws {
    let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    previousAccessibilityValue = NSApplication.shared.accessibilityAttributeValue(
      accessibilityAttribute)
    NSApplication.shared.accessibilitySetValue(true, forAttribute: accessibilityAttribute)
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("menu-notes-scroll-" + UUID().uuidString, isDirectory: true)
    notes = menuScrollWideNotes(count: 3)
    folders = try menuScrollShortFolders(count: 5)
    let state = AppState(
      store: LocalStore(rootURL: root),
      saveOperation: { _, _, _, _ in .committed }
    )
    await state.waitUntilInitialLoad()
    state.workspace = Workspace(
      notes: notes,
      selectedNoteID: notes.first?.id,
      folders: folders
    )
    if let panelWidth, let panelHeight {
      state.preferences.panelWidth = Double(panelWidth)
      state.preferences.panelHeight = Double(panelHeight)
    }
    self.state = state

    if sizing == .storedPreferences, statusButtonFrame == nil {
      throw MenuScrollFixtureError.missingStatusFrame
    }
    let statusFixture: MenuScrollStatusButtonFixture?
    if let frame = statusButtonFrame {
      statusFixture = MenuScrollStatusButtonFixture(screenFrame: frame)
    } else {
      statusFixture = nil
    }
    let geometry: MenuPanelGeometryStore?
    if let fixture = statusFixture {
      let store = MenuPanelGeometryStore(windows: { [fixture.window] })
      store.rememberCompletedSide(.right)
      geometry = store
    } else {
      geometry = nil
    }
    runtime = DictationRuntime(appState: state, applicationSupportURL: root)
    status = statusFixture

    let panel = NotesPanel(
      dictationRuntime: runtime,
      sizing: sizing == .container ? .container : .storedPreferences
    )
    .environmentObject(state)
    let styled = geometry.map { AnyView(panel.environment(\.menuPanelGeometryStore, $0)) }
      ?? AnyView(panel)
    host = NSHostingView(
      rootView: sizing == .container
        ? AnyView(styled.frame(maxWidth: .infinity, maxHeight: .infinity))
        : styled
    )
    window = NSWindow(
      contentRect: CGRect(
        x: statusButtonFrame.map { $0.maxX - width } ?? -10_000,
        y: statusButtonFrame.map { $0.minY - height } ?? -10_000,
        width: width,
        height: height
      ),
      styleMask: sizing == .container ? [.titled, .resizable] : .borderless,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    if sizing == .container {
      window.makeKeyAndOrderFront(nil)
    } else {
      window.orderFront(nil)
    }
    await settle()
  }

  func settle() async {
    await menuScrollSettle(host)
  }

  func resize(to width: CGFloat, height: CGFloat = 430) async {
    window.setContentSize(NSSize(width: width, height: height))
    await settle()
  }

  /// Public AppKit safe-area input on the hosting view's own window: full-size
  /// content plus a toolbar puts the content under the titlebar, which raises
  /// the hosting view's top safe-area inset.
  func setWindowChromeSafeAreaProbe(_ installed: Bool) {
    if installed {
      window.styleMask.insert(.fullSizeContentView)
      let toolbar = NSToolbar(identifier: "menu-notes-scroll-safe-area-probe")
      toolbar.displayMode = .iconOnly
      window.toolbarStyle = .unified
      window.toolbar = toolbar
    } else {
      window.toolbar = nil
      window.styleMask.remove(.fullSizeContentView)
    }
  }

  var tabScrollView: NSScrollView? { menuScrollTabScrollView(in: host) }

  func folderScrollView() throws -> NSScrollView {
    try menuScrollFolderScrollView(in: host)
  }

  var hasTabOverflow: Bool {
    menuScrollElement(host, identifier: "note-tab-overflow-earlier") != nil
      && menuScrollElement(host, identifier: "note-tab-overflow-later") != nil
  }

  var hasFolderOverflow: Bool {
    menuScrollElement(host, label: "Reveal earlier folders") != nil
      && menuScrollElement(host, label: "Reveal later folders") != nil
  }

  var editorString: String? {
    menuScrollDescendants(in: host, as: ListAwareTextView.self).first?.string
  }

  var selectedBody: String? {
    guard let id = state.workspace.selectedNoteID else { return nil }
    return notes.first(where: { $0.id == id })?.body
  }

  func resizeHost() -> MenuPanelResizeHostView? {
    menuScrollDescendants(in: host, as: MenuPanelResizeHostView.self).first
  }

  func close() {
    window.contentView = nil
    window.orderOut(nil)
    window.close()
    status?.close()
    NSApplication.shared.accessibilitySetValue(
      previousAccessibilityValue,
      forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    )
    let runtime = self.runtime
    let root = self.root
    Task {
      await runtime.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private enum MenuScrollFixtureError: Error {
  case missingStatusFrame
}

/// Minimal public-AppKit status button host so `MenuPanelGeometryStore` can
/// resolve a status frame for the resize host without a real menu bar item.
@MainActor
private final class MenuScrollStatusButtonFixture {
  let window: NSWindow

  init(screenFrame: CGRect) {
    let windowFrame = CGRect(
      x: screenFrame.minX - 10,
      y: screenFrame.minY - 6,
      width: max(screenFrame.width + 20, 80),
      height: max(screenFrame.height + 12, 40)
    )
    window = NSWindow(
      contentRect: windowFrame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(origin: .zero, size: windowFrame.size))
    let container = NSView(frame: root.bounds)
    let button = NSStatusBarButton(
      frame: CGRect(x: 10, y: 6, width: screenFrame.width, height: screenFrame.height)
    )
    container.addSubview(button)
    root.addSubview(container)
    window.contentView = root
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
}

// MARK: - Shared strip assertions

@MainActor
private func menuScrollRequireStripStates(
  _ fixture: MenuNotesScrollFixture,
  tabOverflow: Bool,
  folderOverflow: Bool,
  at width: CGFloat
) throws {
  try #require(
    fixture.hasTabOverflow == tabOverflow,
    "Tab overflow at \(width)pt should be \(tabOverflow)"
  )
  try #require(
    fixture.hasFolderOverflow == folderOverflow,
    "Folder overflow at \(width)pt should be \(folderOverflow)"
  )
}

@MainActor
private func menuScrollAssertStrips(
  _ fixture: MenuNotesScrollFixture,
  tab: NSScrollView,
  tabDocument: NSView,
  folder: NSScrollView,
  folderDocument: NSView,
  selected: UUID,
  body: String,
  tabOverflow: Bool,
  folderOverflow: Bool,
  previous: (width: CGFloat, tab: CGFloat, folder: CGFloat, tabOverflow: Bool, folderOverflow: Bool)
) throws {
  let sameTabScroll = fixture.tabScrollView === tab
  let sameTabDocument = tab.documentView === tabDocument
  let folderScroll = try? fixture.folderScrollView()
  let sameFolderScroll = folderScroll === folder
  let sameFolderDocument = folder.documentView === folderDocument
  let sameSelection = fixture.state.workspace.selectedNoteID == selected
  let sameBody = fixture.editorString == body
  #expect(sameTabScroll, "Tab strip rebuilt its scroll view")
  #expect(sameTabDocument, "Tab strip rebuilt its document view")
  #expect(sameFolderScroll, "Folder strip rebuilt its scroll view")
  #expect(sameFolderDocument, "Folder strip rebuilt its document view")
  #expect(sameSelection, "Selection changed")
  #expect(sameBody, "Editor body changed")

  let earlierTab = menuScrollElement(fixture.host, identifier: "note-tab-overflow-earlier")
  let laterTab = menuScrollElement(fixture.host, identifier: "note-tab-overflow-later")
  let earlierFolder = menuScrollElement(fixture.host, label: "Reveal earlier folders")
  let laterFolder = menuScrollElement(fixture.host, label: "Reveal later folders")
  if tabOverflow {
    try #require(earlierTab != nil, "Tab rail is missing while the tab strip overflows")
    try #require(laterTab != nil, "Tab rail is missing while the tab strip overflows")
    #expect(menuScrollAccessibilityLabel(earlierTab) == "Reveal earlier tabs")
    #expect(menuScrollAccessibilityLabel(laterTab) == "Reveal later tabs")
  } else {
    #expect(earlierTab == nil, "Tab rail is shown while the tab strip fits")
    #expect(laterTab == nil, "Tab rail is shown while the tab strip fits")
  }
  if folderOverflow {
    try #require(earlierFolder != nil, "Folder rail is missing while the folder strip overflows")
    try #require(laterFolder != nil, "Folder rail is missing while the folder strip overflows")
    #expect(menuScrollAccessibilityLabel(laterFolder) == "Reveal later folders")
  } else {
    #expect(earlierFolder == nil, "Folder rail is shown while the folder strip fits")
    #expect(laterFolder == nil, "Folder rail is shown while the folder strip fits")
  }

  let deltaWidth = fixture.window.frame.width - previous.width
  let expectedTabDelta =
    deltaWidth - (tabOverflow ? menuScrollTabRail : 0)
    + (previous.tabOverflow ? menuScrollTabRail : 0)
  let expectedFolderDelta =
    deltaWidth - (folderOverflow ? menuScrollFolderRail : 0)
    + (previous.folderOverflow ? menuScrollFolderRail : 0)
  #expect(
    abs((tab.contentView.bounds.width - previous.tab) - expectedTabDelta) <= 2,
    "Tab viewport did not track the resize by one rail decision"
  )
  #expect(
    abs((folder.contentView.bounds.width - previous.folder) - expectedFolderDelta) <= 2,
    "Folder viewport did not track the resize by one rail decision"
  )
}

@MainActor
private func menuScrollMeasureThreshold(
  _ fixture: MenuNotesScrollFixture,
  from high: CGFloat,
  to low: CGFloat,
  isOverflowing: (MenuNotesScrollFixture) -> Bool
) async throws -> CGFloat {
  var fitted = high
  var overflowing: CGFloat?
  var width = high
  while width > low {
    width -= 20
    await fixture.resize(to: width)
    if isOverflowing(fixture) {
      overflowing = width
      break
    }
    fitted = width
  }
  var lower = try #require(
    overflowing, "No overflow crossing between \(high)pt and \(low)pt")
  var upper = fitted
  while upper - lower > 1 {
    let midpoint = (upper + lower) / 2
    await fixture.resize(to: midpoint)
    if isOverflowing(fixture) {
      lower = midpoint
    } else {
      upper = midpoint
    }
  }
  return (upper + lower) / 2
}

// MARK: - Tests

@Test @MainActor
func hostedStripsCrossOverflowOneAtATimeAndSurviveASafeAreaChange() async throws {
  let fixture = try await MenuNotesScrollFixture(width: 1_100, sizing: .container)
  defer { fixture.close() }

  let tab = try #require(fixture.tabScrollView, "The tab strip must host a scroll view")
  let tabDocument = try #require(tab.documentView)
  let folder = try fixture.folderScrollView()
  let folderDocument = try #require(folder.documentView)
  let selected = try #require(fixture.state.workspace.selectedNoteID)
  let body = try #require(fixture.selectedBody)

  // Calibrate the app's own crossings, then derive every test width from them.
  let folderThreshold = try await menuScrollMeasureThreshold(
    fixture, from: 1_100, to: 560
  ) { $0.hasFolderOverflow }
  let tabThreshold = try await menuScrollMeasureThreshold(
    fixture, from: 720, to: 400
  ) { $0.hasTabOverflow }
  let bothFit = max(folderThreshold, tabThreshold) + 60
  let folderOnly = folderThreshold - 40
  let bothOverflow = tabThreshold - 40
  try #require(
    folderOnly > tabThreshold + 20,
    "Folder threshold \(folderThreshold) does not clear tab threshold \(tabThreshold)"
  )
  try #require(
    bothOverflow < folderThreshold - 20,
    "Tab threshold \(tabThreshold) does not clear the folder threshold \(folderThreshold)"
  )

  var previous = (
    width: fixture.window.frame.width,
    tab: tab.contentView.bounds.width,
    folder: folder.contentView.bounds.width,
    tabOverflow: fixture.hasTabOverflow,
    folderOverflow: fixture.hasFolderOverflow
  )
  let states: [(width: CGFloat, tabOverflow: Bool, folderOverflow: Bool)] = [
    (bothFit, false, false),
    (folderOnly, false, true),
    (bothOverflow, true, true),
    (bothFit, false, false),
  ]
  for state in states {
    await fixture.resize(to: state.width)
    try menuScrollRequireStripStates(
      fixture,
      tabOverflow: state.tabOverflow,
      folderOverflow: state.folderOverflow,
      at: state.width
    )
    try menuScrollAssertStrips(
      fixture,
      tab: tab,
      tabDocument: tabDocument,
      folder: folder,
      folderDocument: folderDocument,
      selected: selected,
      body: body,
      tabOverflow: state.tabOverflow,
      folderOverflow: state.folderOverflow,
      previous: previous
    )
    previous = (
      width: fixture.window.frame.width,
      tab: tab.contentView.bounds.width,
      folder: folder.contentView.bounds.width,
      tabOverflow: state.tabOverflow,
      folderOverflow: state.folderOverflow
    )
  }

  // The folder rail's own scroll action must still work through local presses
  // after the strips have crossed both thresholds.
  await fixture.resize(to: bothOverflow)
  try menuScrollRequireStripStates(
    fixture, tabOverflow: true, folderOverflow: true, at: bothOverflow)
  #expect(abs(folder.contentView.bounds.minX) <= 0.5)
  let later = try #require(menuScrollElement(fixture.host, label: "Reveal later folders"))
  #expect(menuScrollPress(later))
  await fixture.settle()
  let trailing = folder.contentView.bounds.minX
  #expect(trailing > 0, "Reveal later folders did not scroll the strip")
  let earlier = try #require(menuScrollElement(fixture.host, label: "Reveal earlier folders"))
  #expect(menuScrollPress(earlier))
  await fixture.settle()
  #expect(folder.contentView.bounds.minX < trailing - 1)

  // Public AppKit safe-area change on the hosting view's window. The premise is
  // required: if the hosting view does not observe the inset, this control is
  // not exercising a safe-area change and must fail.
  let insetsBefore = fixture.host.safeAreaInsets.top
  let tabViewport = tab.contentView.bounds.size
  let folderViewport = folder.contentView.bounds.size
  let folderOffset = folder.contentView.bounds.minX
  fixture.setWindowChromeSafeAreaProbe(true)
  await fixture.settle()
  let insetsAfter = fixture.host.safeAreaInsets.top
  try #require(
    insetsAfter > insetsBefore,
    "The hosting view must observe the window's public AppKit safe-area inset"
  )
  try menuScrollRequireStripStates(
    fixture, tabOverflow: true, folderOverflow: true, at: bothOverflow)
  let sameTabScroll = fixture.tabScrollView === tab
  let sameTabDocument = tab.documentView === tabDocument
  let folderScroll = try? fixture.folderScrollView()
  let sameFolderScroll = folderScroll === folder
  let sameFolderDocument = folder.documentView === folderDocument
  #expect(sameTabScroll, "Tab strip rebuilt its scroll view across a safe-area change")
  #expect(sameTabDocument, "Tab strip rebuilt its document view across a safe-area change")
  #expect(sameFolderScroll, "Folder strip rebuilt its scroll view across a safe-area change")
  #expect(sameFolderDocument, "Folder strip rebuilt its document view across a safe-area change")
  #expect(abs(tab.contentView.bounds.width - tabViewport.width) <= 0.5)
  #expect(abs(folder.contentView.bounds.width - folderViewport.width) <= 0.5)
  #expect(abs(folder.contentView.bounds.minX - folderOffset) <= 0.5)
  #expect(fixture.state.workspace.selectedNoteID == selected)
  #expect(fixture.editorString == body)

  fixture.setWindowChromeSafeAreaProbe(false)
  await fixture.settle()
  try menuScrollRequireStripStates(
    fixture, tabOverflow: true, folderOverflow: true, at: bothOverflow)
  #expect(abs(tab.contentView.bounds.width - tabViewport.width) <= 0.5)
  #expect(abs(folder.contentView.bounds.width - folderViewport.width) <= 0.5)
  await fixture.state.quiescePersistenceForTesting()
}

@Test @MainActor
func hostedMenuResizeReleaseAcrossBothThresholdsKeepsScrollGeometry() async throws {
  let screen = try #require(NSScreen.main)
  let visible = screen.visibleFrame
  try #require(visible.width >= 1_150 && visible.height >= 500)
  let buttonFrame = CGRect(x: visible.maxX - 64, y: visible.maxY + 2, width: 34, height: 22)
  let fixture = try await MenuNotesScrollFixture(
    width: 720,
    height: 415,
    sizing: .storedPreferences,
    statusButtonFrame: buttonFrame,
    panelWidth: 720,
    panelHeight: 415
  )
  defer { fixture.close() }

  let tab = try #require(fixture.tabScrollView)
  let tabDocument = try #require(tab.documentView)
  let folder = try fixture.folderScrollView()
  let folderDocument = try #require(folder.documentView)
  let selected = try #require(fixture.state.workspace.selectedNoteID)
  let body = try #require(fixture.selectedBody)
  let resizeHosts = menuScrollDescendants(in: fixture.host, as: MenuPanelResizeHostView.self)
  try #require(resizeHosts.count == 1, "The stored-preferences panel must install one resize host")
  let resizeHost = try #require(resizeHosts.first)
  let start = resizeHost.convert(
    CGPoint(x: resizeHost.bounds.minX + 1, y: resizeHost.bounds.midY),
    to: nil
  )
  let admitted = await menuScrollResizeBeginReadiness(
    resizeHost, at: start, in: fixture.window)
  try #require(admitted, "Resize admission refused, so the release path was not exercised")

  let screenStart = fixture.window.convertPoint(toScreen: start)
  let startWidth = fixture.window.frame.width
  var last = screenStart
  var eventNumber = 300
  menuScrollSendMouse(.leftMouseDown, at: start, in: fixture.window, number: eventNumber)

  func drag(to width: CGFloat) async throws {
    let from = fixture.window.frame.width
    for step in 1...40 {
      let next = from + (width - from) * CGFloat(step) / 40
      last = CGPoint(x: screenStart.x + startWidth - next, y: screenStart.y)
      eventNumber += 1
      menuScrollSendMouse(
        .leftMouseDragged, atScreen: last, in: fixture.window, number: eventNumber)
      try await Task.sleep(for: .milliseconds(12))
    }
    await fixture.settle()
    #expect(abs(fixture.window.frame.width - width) <= 2)
  }

  var previous = (
    width: fixture.window.frame.width,
    tab: tab.contentView.bounds.width,
    folder: folder.contentView.bounds.width,
    tabOverflow: fixture.hasTabOverflow,
    folderOverflow: fixture.hasFolderOverflow
  )

  // Narrow until both strips must overflow, then widen until both must fit
  // again. The release must not change either state or either viewport.
  try await drag(to: 480)
  try menuScrollRequireStripStates(fixture, tabOverflow: true, folderOverflow: true, at: 480)
  try menuScrollAssertStrips(
    fixture,
    tab: tab,
    tabDocument: tabDocument,
    folder: folder,
    folderDocument: folderDocument,
    selected: selected,
    body: body,
    tabOverflow: true,
    folderOverflow: true,
    previous: previous
  )
  previous = (
    width: fixture.window.frame.width,
    tab: tab.contentView.bounds.width,
    folder: folder.contentView.bounds.width,
    tabOverflow: true,
    folderOverflow: true
  )

  try await drag(to: 1_040)
  try menuScrollRequireStripStates(fixture, tabOverflow: false, folderOverflow: false, at: 1_040)
  try menuScrollAssertStrips(
    fixture,
    tab: tab,
    tabDocument: tabDocument,
    folder: folder,
    folderDocument: folderDocument,
    selected: selected,
    body: body,
    tabOverflow: false,
    folderOverflow: false,
    previous: previous
  )
  let releasedTabViewport = tab.contentView.bounds.width
  let releasedFolderViewport = folder.contentView.bounds.width

  menuScrollSendMouse(
    .leftMouseUp, atScreen: last, in: fixture.window, number: eventNumber + 1)
  try await Task.sleep(for: .milliseconds(300))
  await fixture.settle()

  try menuScrollRequireStripStates(fixture, tabOverflow: false, folderOverflow: false, at: 1_040)
  let sameTabScroll = fixture.tabScrollView === tab
  let sameTabDocument = tab.documentView === tabDocument
  let folderScroll = try? fixture.folderScrollView()
  let sameFolderScroll = folderScroll === folder
  let sameFolderDocument = folder.documentView === folderDocument
  let tabViewport = tab.contentView.bounds.width
  let folderViewport = folder.contentView.bounds.width
  #expect(sameTabScroll, "A release must not rebuild the tab scroll view")
  #expect(sameTabDocument, "A release must not rebuild the tab document view")
  #expect(sameFolderScroll, "A release must not rebuild the folder scroll view")
  #expect(sameFolderDocument, "A release must not rebuild the folder document view")
  #expect(abs(tabViewport - releasedTabViewport) <= 0.5)
  #expect(abs(folderViewport - releasedFolderViewport) <= 0.5)
  #expect(fixture.state.workspace.selectedNoteID == selected)
  #expect(fixture.editorString == body)
  #expect(abs(CGFloat(fixture.state.preferences.panelWidth) - fixture.window.frame.width) <= 2)
  await fixture.state.quiescePersistenceForTesting()
}

@MainActor
private func menuScrollResizeBeginReadiness(
  _ host: MenuPanelResizeHostView,
  at locationInWindow: CGPoint,
  in window: NSWindow
) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(5)
  var readiness = host.beginReadiness(at: locationInWindow, in: window)
  while case .reconciling = readiness, ContinuousClock.now < deadline {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    }
    readiness = host.beginReadiness(at: locationInWindow, in: window)
  }
  guard ContinuousClock.now < deadline else { return false }
  if case .ready = readiness { return true }
  return false
}
