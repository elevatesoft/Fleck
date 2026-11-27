#if os(macOS)
  import AppKit
  import SwiftUI

  struct NotesCascadeItem {
    enum Action {
      case command(() -> Void)
      case submenu([NotesCascadeItem?])
    }

    let title: String
    let icon: String?
    let paperGlyph: NotesPaperIcon.Glyph?
    let help: String?
    let accessibilityLabel: String?
    let value: String?
    let isEnabled: Bool
    let isSelected: Bool
    let role: ButtonRole?
    let shortcut: KeyboardShortcut?
    let action: Action

    init(
      _ title: String, paperGlyph: NotesPaperIcon.Glyph? = nil, help: String? = nil,
      accessibilityLabel: String? = nil, value: String? = nil, shortcut: KeyboardShortcut? = nil,
      isEnabled: Bool = true, isSelected: Bool = false, role: ButtonRole? = nil,
      perform: @escaping () -> Void
    ) {
      self.title = title
      icon = nil
      self.paperGlyph = paperGlyph
      self.help = help
      self.accessibilityLabel = accessibilityLabel
      self.value = value
      self.shortcut = shortcut
      self.isEnabled = isEnabled
      self.isSelected = isSelected
      self.role = role
      action = .command(perform)
    }

    init(
      _ title: String, icon: String? = nil, help: String? = nil, value: String? = nil,
      isEnabled: Bool = true, items: [NotesCascadeItem?]
    ) {
      self.title = title
      self.icon = icon
      paperGlyph = nil
      self.help = help
      accessibilityLabel = nil
      self.value = value
      self.isEnabled = isEnabled
      isSelected = false
      role = nil
      shortcut = nil
      action = .submenu(items)
    }

    var isBranch: Bool {
      if case .submenu = action { return true }
      return false
    }
  }

  struct NotesNativeMenuItems: View {
    let items: [NotesCascadeItem?]

    var body: some View {
      ForEach(items.indices, id: \.self) { index in
        if let item = items[index] {
          NotesNativeMenuItem(item: item)
        } else {
          Divider()
        }
      }
    }
  }

  struct NotesNativeMenuItem: View {
    let item: NotesCascadeItem
    var displayTitle: String? = nil

    var body: some View {
      Group {
        switch item.action {
        case .command(let perform):
          Button(role: item.role, action: perform) {
            if item.isSelected { Label(item.title, systemImage: "checkmark") }
            else { Text(item.title) }
          }
          .keyboardShortcut(item.shortcut)
        case .submenu(let children):
          Menu(displayTitle ?? item.title) { NotesNativeMenuItems(items: children) }
        }
      }
      .disabled(!item.isEnabled)
      .help(item.help ?? "")
      .accessibilityLabel(item.accessibilityLabel ?? item.title)
      .accessibilityValue(item.value ?? "")
    }
  }

  struct NotesFormattingCascade: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    @StateObject private var presenter = NotesCascadePresenter()
    let items: [NotesCascadeItem?]
    let chrome: NotesSolidChrome
    let dismiss: () -> Void

    var body: some View {
      NotesCascadeSurface(items: items, chrome: chrome, style: .root, selection: presenter.rootSelection) {
        [weak presenter] index in presenter?.activate(index, from: nil)
      }
      .background {
        NotesCascadeAnchor { [weak presenter] view in
          presenter?.attachRoot(view.window, items: items, chrome: chrome, theme: theme, dismiss: dismiss)
        } exit: { [weak presenter] window in
          presenter?.pointerExited(window)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .onDisappear { presenter.detachRoot() }
    }
  }

  struct NotesToolsMenu<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fleckThemeSnapshot) private var theme
    @StateObject private var presenter = NotesCascadePresenter()
    let title: String
    let chrome: NotesSolidChrome
    let actions: [NotesCascadeItem?]
    @ViewBuilder let label: () -> Label

    var body: some View {
      Button {
        if presenter.isOpen { presenter.detachRoot() } else { open() }
      } label: {
        label()
          .contentShape(Rectangle())
          .background(presenter.isOpen ? chrome.popoverSelection : .clear,
            in: RoundedRectangle(cornerRadius: 5))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint("Show menu")
      .accessibilityValue(presenter.isOpen ? "Expanded" : "Collapsed")
      .onKeyPress(.downArrow) {
        guard isEnabled, !presenter.isOpen else { return .ignored }
        open(selectFirst: true)
        return .handled
      }
      .background {
        DirectAnchor(presenter: presenter)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { presenter.detachRoot() }
      }
      .onDisappear { presenter.detachRoot() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        presenter.detachRoot()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
        if $0.object as? NSWindow === presenter.trigger?.window { presenter.detachRoot() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) {
        if $0.object as? NSWindow === presenter.trigger?.window { presenter.detachRoot() }
      }
    }

    private func open(selectFirst: Bool = false) {
      presenter.openTools(title: title, items: actions, chrome: chrome, theme: theme, selectFirst: selectFirst)
    }

    private struct DirectAnchor: NSViewRepresentable {
      let presenter: NotesCascadePresenter

      func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.trigger = view
        return view
      }

      func updateNSView(_ view: NSView, context: Context) {
        presenter.trigger = view
      }
    }
  }

  private struct NotesCascadeAnchor: NSViewRepresentable {
    let attach: (NSView) -> Void
    var exit: ((NSWindow?) -> Void)? = nil

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
      view.attach = attach
      view.exit = exit
      attach(view)
    }

    final class Anchor: NSView {
      var attach: ((NSView) -> Void)?
      var exit: ((NSWindow?) -> Void)?
      private var tracking: NSTrackingArea?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach?(self)
      }

      override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard exit != nil else { return }
        let area = NSTrackingArea(rect: .zero,
          options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
      }

      override func mouseExited(with event: NSEvent) { exit?(window) }
    }
  }

  @MainActor private final class NotesCascadeSelection: ObservableObject {
    @Published var highlighted: Int?
    @Published var expanded: Int?
  }

  private enum NotesCascadeStyle {
    case root, child, tools

    var width: CGFloat { self == .root ? 238 : 236 }
    var inset: CGFloat { 7 }

    func height(of item: NotesCascadeItem?) -> CGFloat { item == nil ? 11 : 29 }

    func size(for items: [NotesCascadeItem?]) -> CGSize {
      CGSize(width: width, height: inset * 2 + items.reduce(0) { $0 + height(of: $1) })
    }

    func rowTop(_ index: Int, items: [NotesCascadeItem?], in frame: CGRect) -> CGFloat {
      frame.maxY - inset - items.prefix(index).reduce(0) { $0 + height(of: $1) }
    }

    func row(at point: NSPoint, items: [NotesCascadeItem?], in frame: CGRect) -> Int? {
      guard frame.insetBy(dx: inset, dy: inset).contains(point) else { return nil }
      var y = frame.maxY - inset - point.y
      for (index, item) in items.enumerated() {
        y -= height(of: item)
        if y < 0 { return item == nil ? nil : index }
      }
      return nil
    }
  }

  @MainActor private final class NotesCascadePresenter: ObservableObject {
    weak var trigger: NSView?
    @Published private(set) var isOpen = false
    let rootSelection = NotesCascadeSelection()

    private final class Level {
      let panel: NSPanel
      let items: [NotesCascadeItem?]
      let style: NotesCascadeStyle
      let selection: NotesCascadeSelection
      let prefersLeft: Bool

      init(
        panel: NSPanel, items: [NotesCascadeItem?], style: NotesCascadeStyle,
        selection: NotesCascadeSelection, prefersLeft: Bool
      ) {
        self.panel = panel
        self.items = items
        self.style = style
        self.selection = selection
        self.prefersLeft = prefersLeft
      }
    }

    private struct Context {
      let chrome: NotesSolidChrome
      let theme: FleckThemeSnapshot
    }

    private weak var root: NSWindow?
    private var context: Context?
    private var rootItems: [NotesCascadeItem?] = []
    private var dismissRoot: (() -> Void)?
    private var levels: [Level] = []
    private var eventMonitor: Any?
    private var pending: (depth: Int, index: Int, task: Task<Void, Never>)?
    private var hovered: (depth: Int, index: Int)?
    private var pointer: NSPoint?

    func attachRoot(
      _ window: NSWindow?, items: [NotesCascadeItem?], chrome: NotesSolidChrome,
      theme: FleckThemeSnapshot, dismiss: @escaping () -> Void
    ) {
      guard let window else {
        if dismissRoot != nil { detachRoot() }
        return
      }
      if root !== window { detachRoot() }
      root = window
      window.acceptsMouseMovedEvents = true
      context = Context(chrome: chrome, theme: theme)
      rootItems = items
      dismissRoot = dismiss
      monitorEvents()
    }

    func openTools(
      title: String, items: [NotesCascadeItem?], chrome: NotesSolidChrome,
      theme: FleckThemeSnapshot, selectFirst: Bool
    ) {
      guard let trigger, let owner = trigger.window else { return }
      let anchor = owner.convertToScreen(trigger.convert(trigger.bounds, to: nil))
      root = owner
      context = Context(chrome: chrome, theme: theme)
      present(title, items: items, style: .tools, owner: owner, anchor: anchor, selectFirst: selectFirst)
      if !levels.isEmpty {
        isOpen = true
        monitorEvents()
      }
    }

    func detachRoot() {
      closeLevels(from: 0)
      dismissRoot = nil
      root = nil
      rootItems = []
      rootSelection.highlighted = nil
      hovered = nil
      pointer = nil
      context = nil
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
      }
      if isOpen { isOpen = false }
    }

    func activate(_ index: Int, from panel: NSPanel?) {
      guard let depth = depth(for: panel) else { return }
      activate(index, depth: depth, selectFirst: false)
    }

    func pointerExited(_ window: NSWindow?) {
      guard let hovered, window === state(at: hovered.depth)?.window else { return }
      clearHover()
    }

    private func clearHover() {
      if let hovered, let level = state(at: hovered.depth),
        level.selection.expanded == nil, level.selection.highlighted == hovered.index
      {
        level.selection.highlighted = nil
      }
      hovered = nil
      cancelPending()
    }

    private func movePointer(_ event: NSEvent) {
      guard let window = event.window else { clearHover(); return }
      let depth = window === root && dismissRoot != nil ? 0
        : levels.firstIndex { $0.panel === window }.map { $0 + 1 }
      let point = window.convertPoint(toScreen: event.locationInWindow)
      let previous = pointer
      pointer = point
      guard let depth, let level = state(at: depth),
        let index = level.style.row(at: point, items: level.items, in: window.frame)
      else {
        clearHover()
        return
      }
      let opensOnEntry = dismissRoot != nil && level.items[index]?.isEnabled == true
        && level.items[index]?.isBranch == true
      let previousPoint = previous ?? point
      let minimumHorizontalRatio: CGFloat = opensOnEntry ? 0.25 : 0
      let protectsChild = opensOnEntry && isPointerAimingAtChild(from: previousPoint, depth: depth,
        minimumHorizontalRatio: minimumHorizontalRatio)
      if hovered?.depth == depth && hovered?.index == index {
        if opensOnEntry, !protectsChild, pending?.depth == depth, pending?.index == index, point != previous {
          activate(index, depth: depth, selectFirst: false)
        }
        return
      }
      clearHover()
      hovered = (depth, index)
      if level.selection.expanded == index {
        level.selection.highlighted = index
        return
      }
      if level.selection.expanded == nil {
        level.selection.highlighted = level.items[index]?.isEnabled == true ? index : nil
        guard level.items[index]?.isEnabled == true, level.items[index]?.isBranch == true else { return }
      }
      if opensOnEntry && !protectsChild {
        activate(index, depth: depth, selectFirst: false)
        return
      }
      scheduleHover(index, depth: depth, from: previousPoint, remaining: 2,
        minimumHorizontalRatio: minimumHorizontalRatio)
    }

    private func scheduleHover(
      _ index: Int, depth: Int, from previous: NSPoint, remaining: Int, minimumHorizontalRatio: CGFloat
    ) {
      let delay: Duration = state(at: depth)?.selection.expanded == nil ? .milliseconds(150) : .milliseconds(280)
      pending = (depth, index, Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self, let point = pointer,
          let level = state(at: depth), level.window.isVisible,
          level.items.indices.contains(index)
        else { return }
        pending = nil
        if remaining > 0, isPointerAimingAtChild(from: previous, depth: depth,
          minimumHorizontalRatio: minimumHorizontalRatio)
        {
          scheduleHover(index, depth: depth, from: point, remaining: remaining - 1,
            minimumHorizontalRatio: minimumHorizontalRatio)
          return
        }
        if let item = level.items[index], item.isEnabled, item.isBranch {
          activate(index, depth: depth, selectFirst: false)
        } else {
          closeLevels(from: depth)
          level.selection.highlighted = level.items[index]?.isEnabled == true ? index : nil
        }
      })
    }

    private func isPointerAimingAtChild(from previous: NSPoint, depth: Int, minimumHorizontalRatio: CGFloat) -> Bool {
      guard let pointer, let parent = state(at: depth), let child = state(at: depth + 1) else { return false }
      guard abs(pointer.x - previous.x) >= abs(pointer.y - previous.y) * minimumHorizontalRatio else { return false }
      return Self.movingTowardChild(from: previous, to: pointer, child: child.window.frame,
        parent: parent.window.frame)
    }

    private static func movingTowardChild(from old: NSPoint, to new: NSPoint, child: NSRect, parent: NSRect) -> Bool {
      let opensLeft = child.midX < parent.midX
      let edge = opensLeft ? child.maxX : child.minX
      let deltaX = new.x - old.x
      guard abs(deltaX) >= 2, (opensLeft ? deltaX < 0 : deltaX > 0),
        abs(edge - new.x) < abs(edge - old.x)
      else { return false }
      let progress = min(1, abs(deltaX / (edge - old.x)))
      let low = old.y + (child.minY - 6 - old.y) * progress
      let high = old.y + (child.maxY + 6 - old.y) * progress
      return (low...high).contains(new.y)
    }

    private func depth(for panel: NSPanel?) -> Int? {
      guard let panel else { return dismissRoot == nil ? nil : 0 }
      return levels.firstIndex { $0.panel === panel }.map { $0 + 1 }
    }

    private func state(at depth: Int) -> (
      window: NSWindow, items: [NotesCascadeItem?], style: NotesCascadeStyle,
      selection: NotesCascadeSelection, prefersLeft: Bool
    )? {
      if depth == 0, let root, dismissRoot != nil {
        return (root, rootItems, .root, rootSelection, false)
      }
      guard depth > 0, levels.indices.contains(depth - 1) else { return nil }
      let level = levels[depth - 1]
      return (level.panel, level.items, level.style, level.selection, level.prefersLeft)
    }

    private func activate(_ index: Int, depth: Int, selectFirst: Bool) {
      guard let level = state(at: depth), level.items.indices.contains(index),
        let item = level.items[index], item.isEnabled
      else { return }
      cancelPending()
      switch item.action {
      case .command(let perform):
        if dismissRoot == nil { detachRoot() } else { closeLevels(from: 0) }
        perform()
      case .submenu(let children):
        if level.selection.expanded == index {
          if selectFirst, let child = state(at: depth + 1) {
            child.selection.highlighted = child.items.firstIndex { $0?.isEnabled == true }
          }
          return
        }
        closeLevels(from: depth)
        level.selection.highlighted = index
        let frame = level.window.frame
        let rowTop = level.style.rowTop(index, items: level.items, in: frame)
        present(item.title, items: children, style: .child, owner: level.window,
          anchor: CGRect(x: frame.minX, y: rowTop - 29, width: frame.width, height: 29),
          prefersLeft: level.prefersLeft, selectFirst: selectFirst)
        if state(at: depth + 1) != nil { level.selection.expanded = index }
      }
    }

    private func present(
      _ title: String, items: [NotesCascadeItem?], style: NotesCascadeStyle, owner: NSWindow,
      anchor: NSRect, prefersLeft: Bool = false, selectFirst: Bool
    ) {
      guard owner.isVisible, let screen = owner.screen, let context else { return }
      let placement: NotesMenuPlacement = style == .tools ? .belowTrailing : .alongside
      let frame = placement.frame(anchor: anchor, menuSize: style.size(for: items), screen: screen.visibleFrame,
        firstRowInset: style == .child ? style.inset : 0, prefersLeft: prefersLeft)
      let panel = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
      )
      panel.title = title
      panel.isReleasedWhenClosed = false
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.animationBehavior = .none
      panel.becomesKeyOnlyIfNeeded = true
      panel.acceptsMouseMovedEvents = true
      panel.isExcludedFromWindowsMenu = true
      panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
      panel.appearance = owner.appearance
      let selection = NotesCascadeSelection()
      selection.highlighted = selectFirst ? items.firstIndex { $0?.isEnabled == true } : nil
      panel.contentView = MenuHostingView(rootView: NotesCascadeSurface(
        items: items, chrome: context.chrome, style: style, selection: selection,
        activate: { [weak self, weak panel] index in
          if let panel { self?.activate(index, from: panel) }
        }
      )
      .background {
        NotesCascadeAnchor(attach: { _ in }, exit: { [weak self] in self?.pointerExited($0) })
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .background(context.chrome.popoverSurface, in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(context.chrome.popoverOutline).allowsHitTesting(false) }
      .environment(\.fleckThemeSnapshot, context.theme)
      .environment(\.colorScheme, context.theme.colorScheme)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title))
      levels.append(Level(panel: panel, items: items, style: style, selection: selection,
        prefersLeft: style == .child && frame.midX < anchor.midX))
      owner.addChildWindow(panel, ordered: .above)
      panel.orderFront(nil)
    }

    private func closeLevels(from index: Int) {
      cancelPending()
      state(at: index)?.selection.expanded = nil
      if let hovered, hovered.depth > index { self.hovered = nil }
      let closing = Array(levels.dropFirst(index).reversed())
      levels.removeLast(closing.count)
      for level in closing {
        level.panel.parent?.removeChildWindow(level.panel)
        level.panel.orderOut(nil)
        level.panel.contentView = nil
        level.panel.close()
      }
    }

    private func cancelPending() {
      pending?.task.cancel()
      pending = nil
    }

    private func monitorEvents() {
      guard eventMonitor == nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self else { return event }
        return handle(event)
      }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard let root, root.isVisible else {
        detachRoot()
        return event
      }
      if event.type == .mouseMoved {
        movePointer(event)
        return event
      }
      if event.type != .keyDown {
        if let window = event.window, levels.contains(where: { $0.panel === window }) { return event }
        if event.window === root {
          if dismissRoot != nil { return event }
          if let trigger, trigger.bounds.contains(trigger.convert(event.locationInWindow, from: nil)) {
            return event
          }
        }
        detachRoot()
        return event
      }
      guard let window = event.window ?? NSApp.keyWindow,
        window === root || levels.contains(where: { $0.panel === window }),
        let level = state(at: levels.count)
      else { return event }
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
        let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
      else {
        if dismissRoot == nil { detachRoot() } else { closeLevels(from: 0) }
        return event
      }

      let depth = levels.count
      let enabled = level.items.indices.filter { level.items[$0]?.isEnabled == true }
      switch Int(scalar.value) {
      case NSUpArrowFunctionKey, NSDownArrowFunctionKey:
        moveSelection(level.selection, among: enabled, backwards: scalar.value == NSUpArrowFunctionKey)
      case NSHomeFunctionKey, NSEndFunctionKey:
        cancelPending()
        level.selection.highlighted = scalar.value == NSHomeFunctionKey ? enabled.first : enabled.last
      case 13, 3, 32:
        if let index = level.selection.highlighted ?? enabled.first {
          activate(index, depth: depth, selectFirst: true)
        }
      case NSRightArrowFunctionKey:
        if let index = level.selection.highlighted, level.items[index]?.isBranch == true {
          activate(index, depth: depth, selectFirst: true)
        }
      case 27, NSLeftArrowFunctionKey:
        if depth > 1 || (depth == 1 && dismissRoot != nil) { closeLevels(from: depth - 1) }
        else if let dismissRoot {
          guard scalar.value == 27 else { return event }
          detachRoot()
          dismissRoot()
        } else { detachRoot() }
      case 9, 25:
        guard dismissRoot != nil else { detachRoot(); return event }
        closeLevels(from: 0)
        moveSelection(rootSelection, among: rootItems.indices.filter { rootItems[$0]?.isEnabled == true },
          backwards: scalar.value == 25 || event.modifierFlags.contains(.shift))
      default:
        if let match = enabled.first(where: {
          level.items[$0]?.title.range(of: String(scalar), options: [.caseInsensitive, .anchored]) != nil
        }) {
          cancelPending()
          level.selection.highlighted = match
        } else if depth == 0 {
          return event
        }
      }
      return nil
    }

    private func moveSelection(_ selection: NotesCascadeSelection, among enabled: [Int], backwards: Bool) {
      cancelPending()
      hovered = nil
      if let current = selection.highlighted, let index = enabled.firstIndex(of: current) {
        let step = backwards ? -1 : 1
        selection.highlighted = enabled[(index + step + enabled.count) % enabled.count]
      } else {
        selection.highlighted = backwards ? enabled.last : enabled.first
      }
    }

    private final class MenuHostingView<Content: View>: NSHostingView<Content> {
      override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
  }

  private struct NotesCascadeSurface: View {
    let items: [NotesCascadeItem?]
    let chrome: NotesSolidChrome
    let style: NotesCascadeStyle
    @ObservedObject var selection: NotesCascadeSelection
    let activate: (Int) -> Void

    var body: some View {
      VStack(spacing: 0) {
        ForEach(items.indices, id: \.self) { index in
          if let item = items[index] {
            Button(role: item.role) { activate(index) } label: {
              HStack(spacing: 8) {
                if let glyph = item.paperGlyph {
                  NotesPaperIcon(glyph: glyph, drawSize: 15).frame(width: 18).accessibilityHidden(true)
                } else if style == .root || style == .child {
                  Group {
                    if let icon = item.icon {
                      Image(systemName: icon).font(.system(size: 15))
                    } else if item.isSelected {
                      Image(systemName: "checkmark").font(.system(size: 10, weight: .medium))
                    } else {
                      Color.clear
                    }
                  }
                  .frame(width: 18)
                  .accessibilityHidden(true)
                }
                Text(item.title)
                  .font(.system(size: 12, weight: chrome.increasedContrast ? .regular : style == .root ? .light : .thin))
                  .tracking(chrome.increasedContrast || style == .root ? 0 : 0.15)
                  .foregroundStyle(Color(nsColor: NSColor(hex: chrome.increasedContrast ? "#F2F2F0" : "#FAFAF8")!))
                Spacer(minLength: 0)
                if item.isBranch {
                  Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 10)
                    .accessibilityHidden(true)
                }
              }
              .padding(.horizontal, 8)
              .frame(height: style.height(of: item))
              .contentShape(Rectangle())
              .background(selection.highlighted == index ? chrome.popoverSelection : .clear,
                in: RoundedRectangle(cornerRadius: 5))
              .overlay {
                if chrome.increasedContrast && selection.highlighted == index {
                  RoundedRectangle(cornerRadius: 5).strokeBorder(chrome.popoverOutline)
                    .allowsHitTesting(false)
                }
              }
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
            .opacity(item.isEnabled ? 1 : 0.45)
            .help(item.help ?? "")
            .keyboardShortcut(item.shortcut)
            .accessibilityLabel(item.accessibilityLabel ?? item.title)
            .accessibilityValue(item.value ?? (item.isBranch
              ? (selection.expanded == index ? "Expanded" : "Collapsed") : ""))
            .accessibilityHint(item.isBranch ? "Show menu" : "")
            .accessibilityAddTraits(item.isSelected || selection.highlighted == index ? .isSelected : [])
          } else {
            Rectangle().fill(chrome.popoverSeparator)
              .frame(height: 1)
              .padding(.horizontal, 7)
              .padding(.vertical, 5)
              .accessibilityHidden(true)
          }
        }
      }
      .padding(style.inset)
      .frame(width: style.width)
    }
  }
#endif
