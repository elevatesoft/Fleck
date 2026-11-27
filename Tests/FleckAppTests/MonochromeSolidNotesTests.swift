#if os(macOS)
  import AppKit
  import FleckCore
  import ImageIO
  import ScreenCaptureKit
  import SwiftUI
  import Testing

  @testable import FleckApp

  @MainActor
  struct MonochromeSolidNotesTests {
    private static let graphiteBody = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."

    private static func graphiteWorkspace() throws -> (Workspace, Note) {
      let folders = try ["School", "Dev", "Test"].map { try Folder(name: $0) }
      let active = Note(title: "Test", body: graphiteBody, folderID: folders[2].id)
      let otherNotes = folders.prefix(2).enumerated().flatMap { index, folder in
        (1...(index == 0 ? 3 : 5)).map { Note(title: "Fixture \($0)", folderID: folder.id) }
      }
      return (Workspace(
        notes: otherNotes + [active], selectedNoteID: active.id, folders: folders
      ), active)
    }

    private static var graphitePreferences: AppPreferences {
      var preferences = AppPreferences()
      preferences.theme = .dark
      preferences.colorTheme = .monochrome
      preferences.chromeAppearance = .solid
      preferences.fontFamily = "Avenir Next"
      preferences.fontSize = 17
      preferences.isUnfiledCompact = true
      preferences.showFormattingBar = true
      preferences.showDictationShortcutGuide = false
      return preferences
    }

    @Test func darkNotesTabCapsulesLeaveTheTabStripLayoutIntact() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let originalAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      defer { NSApp.accessibilitySetValue(originalAX, forAttribute: enhancedAX) }
      let folders = try ["School", "Dev", "Test"].map { try Folder(name: $0) }
      let notes = ["Study schedule", "Working notes", "Reading list", "Open questions", "Weekly review"]
        .enumerated().map { index, title in
          Note(title: title, body: "Synthetic notes",
            tabColorHex: index < 2 ? "#763F64" : nil, folderID: folders[2].id)
        }
      let selected = try #require(notes.first)
      let store = LocalStore(rootURL: root)
      try await store.save(workspace: Workspace(notes: notes, selectedNoteID: selected.id, folders: folders),
        preferences: Self.graphitePreferences, trashedNotes: [])
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      func tabDestination(in view: NSView) -> FluidTabDestinationView? {
        if let destination = view as? FluidTabDestinationView { return destination }
        return view.subviews.lazy.compactMap { tabDestination(in: $0) }.first
      }
      for (width, shouldOverflow) in [(686, false), (380, true)] {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 436),
          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
          NotesPanel(dictationRuntime: runtime, sizing: .container)
            .frame(width: CGFloat(width), height: 436)
        })
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Self.awaitKeyWindow(window)
        for _ in 0..<20 {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(10))
        }
        let destination = try #require(tabDestination(in: host))
        let source = try #require(destination.sourceView(for: selected.id))
        let labelFrame = destination.convert(source.labelCapsuleRect, from: source)
        let highlight = destination.selectionHighlightLayer
        #expect(highlight.bounds.size == CGSize(width: labelFrame.width + 4, height: labelFrame.height + 4))
        #expect(highlight.position == CGPoint(x: labelFrame.midX, y: labelFrame.midY))
        #expect(labelFrame.height >= 28)
        #expect(!Self.accessibilityElements(in: host, label: "School").isEmpty)
        if !shouldOverflow {
          #expect(!Self.accessibilityElements(in: host, label: "Dev").isEmpty)
        }
        #expect(!Self.accessibilityElements(in: host, label: "Reveal earlier tabs").isEmpty == shouldOverflow)
        #expect(!Self.accessibilityElements(in: host, label: "Reveal later tabs").isEmpty == shouldOverflow)
        #expect(state.workspace.selectedNoteID == selected.id)
        let frames = destination.sourceFrames().values.sorted { $0.minX < $1.minX }
        #expect(frames.count == notes.count)
        let inactive = try #require(destination.sourceView(for: notes[1].id))
        let hover = destination.hoverHighlightLayer
        let expectedHover = destination.convert(inactive.labelCapsuleRect, from: inactive)
          .insetBy(dx: -2, dy: -2)
        func movePointer(to point: NSPoint, in view: NSView) async throws {
          let windowPoint = view.convert(point, to: nil)
          let screenPoint = window.convertPoint(toScreen: windowPoint)
          try Self.movePointer(in: window, to: CGRect(origin: screenPoint, size: .zero))
          try await Task.sleep(for: .milliseconds(30))
        }
        try await movePointer(to: NSPoint(x: 3, y: inactive.bounds.midY), in: inactive)
        #expect(!hover.isHidden)
        #expect(hover.frame == expectedHover)
        try await movePointer(to: NSPoint(x: inactive.bounds.midX, y: inactive.bounds.midY), in: inactive)
        #expect(!hover.isHidden)
        #expect(hover.frame == expectedHover)
        #expect(state.workspace.selectedNoteID == selected.id)
        try await movePointer(to: NSPoint(x: source.bounds.midX, y: source.bounds.midY), in: source)
        #expect(hover.isHidden)
        try await movePointer(to: NSPoint(x: inactive.bounds.midX, y: inactive.bounds.midY), in: inactive)
        #expect(!hover.isHidden)
        try await movePointer(to: NSPoint(x: 50, y: 55), in: host)
        #expect(hover.isHidden)
        print("NOTE_TAB_LAYOUT width=\(width) frames=\(frames) capsule=\(highlight.frame) overflow=\(shouldOverflow)")
        if try Self.evidenceDirectory() != nil {
          try await Self.captureCompositedWindow(window, name: "dark-note-tabs-\(width)")
        }
      }
      await runtime.shutdown()
    }

    @Test func notesChromeOnlyAppliesToDarkMonochromeSolid() {
      for family: FleckColorTheme in [.monochrome, .capy] {
        for mode: AppTheme in [.light, .dark] {
          let theme = FleckThemeSnapshot.resolve(
            colorTheme: family, mode: mode, systemAppearance: .dark,
            reduceTransparency: true, increasedContrast: true
          )
          #expect(NotesSolidChrome(theme: theme, appearance: .solid).isActive
            == (family == .monochrome && mode == .dark))
          #expect(!NotesSolidChrome(theme: theme, appearance: .glass).isActive)
        }
      }
    }

    @Test func toolsMenuPrefersItsAnchorAndFitsTheUsableDisplay() {
      let size = CGSize(width: 236, height: 199)
      let screen = CGRect(x: -800, y: 24, width: 800, height: 720)
      let anchor = CGRect(x: -440, y: 500, width: 28, height: 28)
      #expect(NotesMenuPlacement.belowTrailing.frame(anchor: anchor, menuSize: size, screen: screen)
        == CGRect(x: -648, y: 297, width: 236, height: 199))
      let lowLeft = CGRect(x: -788, y: 40, width: 28, height: 29)
      #expect(NotesMenuPlacement.belowTrailing.frame(anchor: lowLeft, menuSize: size, screen: screen)
        == CGRect(x: -800, y: 73, width: 236, height: 199))
      #expect(NotesMenuPlacement.alongside.frame(anchor: lowLeft, menuSize: size, screen: screen)
        == CGRect(x: -756, y: 24, width: 236, height: 199))
      let highRight = CGRect(x: -236, y: 713, width: 224, height: 29)
      #expect(NotesMenuPlacement.alongside.frame(anchor: highRight, menuSize: size, screen: screen)
        == CGRect(x: -476, y: 543, width: 236, height: 199))
      #expect(NotesMenuPlacement.alongside.frame(anchor: anchor, menuSize: size, screen: screen)
        == CGRect(x: -408, y: 329, width: 236, height: 199))
      let row = CGRect(x: -525, y: 500, width: 238, height: 29)
      let child = NotesMenuPlacement.alongside.frame(
        anchor: row, menuSize: size, screen: screen, firstRowInset: 7
      )
      #expect(child.minX == row.maxX + 4 && child.maxY - 7 == row.maxY)
      let leftChild = NotesMenuPlacement.alongside.frame(
        anchor: row, menuSize: size, screen: screen, firstRowInset: 7, prefersLeft: true
      )
      #expect(leftChild.maxX == row.minX - 4 && leftChild.maxY - 7 == row.maxY)
      let clamped = NotesMenuPlacement.alongside.frame(
        anchor: lowLeft, menuSize: size, screen: screen, firstRowInset: 7
      )
      #expect(clamped.minY == screen.minY && screen.contains(clamped))
    }

    @Test func populatedHeaderIconsKeepPaperSizesAndCenterlines() {
      let bell = NotesPaperIcon.Glyph.bell
      let backlinks = NotesPaperIcon.Glyph.backlinks
      let pin = NotesPaperIcon.Glyph.pin

      #expect([bell, backlinks, pin].map(\.size) == [18, 18, 18])
      #expect([bell, backlinks, pin].map(\.viewBox) == [20, 24, 24])
      #expect([bell, backlinks, pin].map(\.strokeWidth) == [1.3, 2, 2])
      #expect([bell, backlinks, pin].map(\.ink) == ["#DCE2E6", "#C4C7CA", "#C4C7CA"])

      // Measure the native Path, without starting the app or relying on a font.
      for (glyph, expected): (NotesPaperIcon.Glyph, CGRect) in [
        (bell, CGRect(x: 3, y: 3, width: 14, height: 14)),
        (backlinks, CGRect(x: 2.06, y: 2.07, width: 19.89, height: 19.87)),
        (pin, CGRect(x: 5, y: 2, width: 14, height: 20)),
      ] {
        let actual = glyph.outline.cgPath.boundingBoxOfPath
        #expect(abs(actual.minX - expected.minX) < 0.05)
        #expect(abs(actual.minY - expected.minY) < 0.05)
        #expect(abs(actual.maxX - expected.maxX) < 0.05)
        #expect(abs(actual.maxY - expected.maxY) < 0.05)
      }
    }

    @Test func darkSolidFormattingAndFolderVectorsKeepPaperGeometry() {
      let expected: [(NotesPaperIcon.Glyph, CGFloat, CGRect)] = [
        (.newFolder, 18, CGRect(x: 2, y: 3, width: 20, height: 17)),
        (.bold, 17, CGRect(x: 6, y: 4, width: 13, height: 16)),
        (.italic, 17, CGRect(x: 5, y: 4, width: 14, height: 16)),
        (.underline, 17, CGRect(x: 4, y: 4, width: 16, height: 16)),
        (.strikethrough, 17, CGRect(x: 4, y: 4, width: 16, height: 16)),
      ]
      for (glyph, size, bounds) in expected {
        #expect(glyph.size == size)
        #expect(glyph.viewBox == 24)
        #expect(glyph.strokeWidth == 2)
        let actual = glyph.outline.cgPath.boundingBoxOfPath
        #expect(abs(actual.minX - bounds.minX) < 0.05)
        #expect(abs(actual.minY - bounds.minY) < 0.05)
        #expect(abs(actual.maxX - bounds.maxX) < 0.05)
        #expect(abs(actual.maxY - bounds.maxY) < 0.05)
      }
    }

    @Test func darkSolidChromeInsetsKeepTheWindowEdgeDistanceThroughResizeSideChanges() throws {
      let theme = FleckThemeSnapshot.resolve(
        colorTheme: .monochrome, mode: .dark, systemAppearance: .dark,
        reduceTransparency: false, increasedContrast: false
      )
      let chrome = NotesSolidChrome(theme: theme, appearance: .solid)
      let bounds = CGRect(x: 0, y: 0, width: 686, height: 436)
      for side: MenuPanelFixedSide in [.left, .right] {
        let layout = try #require(MenuPanelResizeGeometry.layout(in: bounds, fixedSide: side))
        let reserve = layout.swiftUIBodyInsets
        let bar = chrome.windowEdgePadding(horizontal: 11, after: reserve)
        let error = chrome.windowEdgePadding(horizontal: 11, bottom: 12, after: reserve)
        #expect(bar.leading + reserve.leading == 11)
        #expect(bar.trailing + reserve.trailing == 11)
        #expect(error.leading + reserve.leading == 11)
        #expect(error.trailing + reserve.trailing == 11)
        #expect(error.bottom + reserve.bottom == 12)
      }
    }

    @Test func markdownExportWritesExactBytesThroughTheNotesDocumentBoundary() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-export-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let body = "# Handoff\n\n- Preserve café, 中文, and 👋.\n"
      let export = PreparedNoteFileExport(note: Note(title: "Release/Review", body: body), format: .markdown)
      #expect(export.filename == "Release-Review.md")
      #expect(export.type == NoteFileDocument.markdownContentType)

      let output = root.appendingPathComponent(export.filename)
      try export.document.exportFileWrapper().write(to: output, options: .atomic, originalContentsURL: nil)
      #expect(try Data(contentsOf: output) == Data(body.utf8))
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Release-Review.md"])
    }

    @Test func populatedNotesEditorRetainsBoldItalicAndFontAcrossReopening() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-notes-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      let (workspace, note) = try Self.graphiteWorkspace()
      let discarded = (1...9).map { Note(title: "Discarded fixture \($0)") }
      try await store.save(
        workspace: workspace, preferences: Self.graphitePreferences, trashedNotes: discarded
      )
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      state.agentActivityIndicator.receive(.began(requestID: UUID(), profileID: UUID()))

      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      let commands = EditorCommands()
      let host = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
        NotesPanel(dictationRuntime: runtime, sizing: .container, editorCommands: commands)
          .frame(width: 686, height: 436)
      })
      let liveCapture = ProcessInfo.processInfo.environment["FLECK_TOOLBAR_WINDOW_CAPTURE"] == "1"
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let previousAX = liveCapture ? NSApp.accessibilityAttributeValue(enhancedAX) : nil
      if liveCapture { NSApp.accessibilitySetValue(true, forAttribute: enhancedAX) }
      defer { if liveCapture { NSApp.accessibilitySetValue(previousAX, forAttribute: enhancedAX) } }
      let window = NotesEvidenceWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 686, height: 436),
        styleMask: .borderless, backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.backgroundColor = .clear
      window.isOpaque = false
      window.contentView = host
      if liveCapture {
        window.hasShadow = false
        window.center()
        window.makeKeyAndOrderFront(nil)
      } else {
        window.orderBack(nil)
      }
      defer {
        window.contentView = nil
        window.close()
      }
      for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        await Task.yield()
      }
      do {
        let editor = try #require(commands.textView)
        #expect(editor.string == Self.graphiteBody)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        #expect(window.makeFirstResponder(editor))
        window.displayIfNeeded()
        if liveCapture {
          try await Self.captureCompositedWindow(window, name: "main-before-format")
        }
        let referenceFamily = NSFont(name: "Times", size: 28) != nil ? "Times" : "Times New Roman"
        commands.applyFontFamily(referenceFamily)
        #expect(commands.applyFontSize(28))
        if !commands.isBold { commands.toggleBold() }
        for _ in 0..<8 {
          host.layoutSubtreeIfNeeded()
          await Task.yield()
        }
        try Self.captureIfRequested(host, name: "76R-0")
        #expect(state.selectedNote?.body == Self.graphiteBody)
        #expect(commands.currentFontFamily == referenceFamily)
        #expect(commands.currentFontSize == 28 && commands.isBold && !commands.isItalic)
        if liveCapture {
          try await Self.captureCompositedWindow(window, name: "main-after-format")
          let fonts = Self.accessibilityElements(in: host, label: "Font")
          #expect(fonts.count == 1)
          let font = try #require(fonts.first)
          #expect(Self.accessibilityString(font, property: "accessibilityValue") == referenceFamily)
          let bodyFont = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
          #expect(bodyFont.familyName == "Avenir Next")
          #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
        }
        let tab = try #require(Self.selectedTabSource(in: host, noteID: note.id))
        let label = try Self.bitmap(of: tab)
        let hasLightInk = (0..<label.pixelsHigh).contains { y in
          (0..<label.pixelsWide).contains { x in
            guard let color = label.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.7
              && min(color.redComponent, color.greenComponent, color.blueComponent) > 0.65
          }
        }
        #expect(hasLightInk, "The native selected tab label must paint light ink")
        try Self.captureIfRequested(tab, name: "selected-tab-host")

        let selection = NSRange(location: 0, length: 5)
        editor.setSelectedRange(selection)
        let currentNote = try #require(state.selectedNote)
        let target = try #require(FontPickerTarget(note: currentNote, isTitle: false, commands: commands))
        #expect(target.apply(
          "Georgia", note: state.selectedNote, isEditorVisible: true,
          commands: commands, titleMutation: { _ in Issue.record("Changed the title instead of the body") }
        ))
        commands.toggleBold()
        commands.toggleItalic()
        #expect(editor.selectedRange() == selection)
        #expect(commands.isBold && commands.isItalic)
        try await state.saveNow().value

        let reopened = try await store.loadSnapshot()
        let saved = try #require(reopened.workspace.notes.first { $0.id == note.id })
        #expect(saved.body == Self.graphiteBody)
        let data = try #require(saved.richTextRTF)
        let decoded = try NoteRichTextCodec.decode(data)
        let font = try #require(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Georgia")
        #expect(NSFontManager.shared.traits(of: font).contains([.boldFontMask, .italicFontMask]))
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    @Test func darkWorkspaceSearchAndNoteLinkPickerUseTheNotesWindow() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-notes-search-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      var (workspace, active) = try Self.graphiteWorkspace()
      let dev = try #require(workspace.folders.first { $0.name == "Dev" })
      let referenceNotes = [
        ("Release checklist", "Finish release notes and check the signed build."),
        ("Product brief", "A calmer place for notes, dictation and useful tools."),
        ("Weekly journal", "Release the first beta, then collect early feedback."),
      ].enumerated().map { index, reference in
        Note(title: reference.0, body: reference.1,
          modifiedAt: Date(timeIntervalSince1970: Double(30 - index)), folderID: dev.id)
      }
      workspace = Workspace(notes: referenceNotes + [active], selectedNoteID: active.id, folders: workspace.folders)
      try await store.save(workspace: workspace, preferences: Self.graphitePreferences)
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      let noMatch = "no matching fixture"
      let search = WorkspaceSearchController { query, notes, limit in
        if query == noMatch {
          do { try await Task.sleep(for: .milliseconds(300)) }
          catch { return [] }
        }
        return await WorkspaceSearchEngine().search(query: query, in: notes, limit: limit)
      }
      let links = NoteLinkPickerController()
      let host = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
        NotesPanel(
          dictationRuntime: runtime, sizing: .container,
          searchController: search, noteLinkPickerController: links
        )
        .frame(width: 686, height: 436)
      })
      let window = NSWindow(
        contentRect: .init(x: -10_000, y: -10_000, width: 686, height: 436),
        styleMask: .borderless, backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host
      window.orderBack(nil)
      defer {
        window.contentView = nil
        window.close()
      }
      func settle(until ready: () -> Bool = { true }) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(25))
          host.layoutSubtreeIfNeeded()
          if ready() { return }
        } while clock.now < deadline
        try #require(ready())
      }
      do {
        try await settle()
        search.present(for: active.id)
        try await settle { search.isPresented && search.results.isEmpty }
        try Self.captureIfRequested(host, name: "workspace-search-ready")
        search.query = "release"
        try await settle { search.resultsAreCurrent && search.results.count == 2 }
        #expect(search.results.map(\.noteID) == [referenceNotes[0].id, referenceNotes[2].id])
        try Self.captureIfRequested(host, name: "workspace-search-results")
        search.query = noMatch
        try await settle { !search.resultsAreCurrent && search.results.count == 2 }
        try Self.captureIfRequested(host, name: "workspace-search-updating")
        try await settle { search.resultsAreCurrent && search.results.isEmpty }
        try Self.captureIfRequested(host, name: "workspace-search-no-matches")
        search.dismiss()
        try await settle { !search.isPresented }

        let source = try #require(state.selectedNote)
        links.present(
          sourceNoteID: source.id, replacementRange: NSRange(location: 0, length: 0),
          sourceRevision: source.revision
        )
        try await settle { links.isShowingRecentNotes && links.results.count == referenceNotes.count }
        #expect(links.results.map(\.noteID) == referenceNotes.map(\.id))
        try Self.captureIfRequested(host, name: "note-link-recent")
        links.query = "release"
        try await settle { links.resultsAreCurrent && links.results.count == 2 }
        try Self.captureIfRequested(host, name: "note-link-results")
        links.query = noMatch
        try await settle { links.resultsAreCurrent && links.results.isEmpty }
        try Self.captureIfRequested(host, name: "note-link-no-matches")
        links.dismiss()
        try await settle()
        state.workspace = Workspace(notes: [source], selectedNoteID: source.id, folders: workspace.folders)
        links.present(
          sourceNoteID: source.id, replacementRange: NSRange(location: 0, length: 0),
          sourceRevision: source.revision
        )
        try await settle { links.isShowingRecentNotes && links.resultsAreCurrent && links.results.isEmpty }
        try Self.captureIfRequested(host, name: "note-link-only-this-note")
        links.dismiss()
        #expect(state.selectedNote?.id == source.id)
        #expect(state.selectedNote?.body == Self.graphiteBody)
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLECK_TOOLBAR_WINDOW_CAPTURE"] == "1"))
    func darkNotesFeedbackCapturesAnActualDelayedWriteAndBannerPresentation() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-notes-feedback-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      let (workspace, note) = try Self.graphiteWorkspace()
      try await store.save(workspace: workspace, preferences: Self.graphitePreferences,
        trashedNotes: (1...9).map { Note(title: "Discarded fixture \($0)") })
      let state = AppState(store: store, saveOperation: { workspace, preferences, trashedNotes, generation in
        try await Task.sleep(for: .seconds(2))
        return try await store.save(workspace: workspace, preferences: preferences,
          trashedNotes: trashedNotes, generation: generation)
      })
      await state.waitUntilInitialLoad()
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      let commands = EditorCommands()
      let controller = NSHostingController(rootView: FleckThemeTestRoot(state: state) {
        NotesPanel(dictationRuntime: runtime, sizing: .container, editorCommands: commands)
          .frame(width: 686, height: 436)
      })
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 686, height: 436),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let previousAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.hasShadow = false
      window.contentViewController = controller
      window.center()
      window.makeKeyAndOrderFront(nil)
      defer {
        window.close()
        NSApp.accessibilitySetValue(previousAX, forAttribute: enhancedAX)
      }
      let host = controller.view
      func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
      }
      do {
        try await Self.awaitKeyWindow(window)
        try await settle { commands.textView != nil }
        let editor = try #require(commands.textView)
        editor.isContinuousSpellCheckingEnabled = false
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        commands.applyFontFamily(NSFont(name: "Times", size: 28) == nil ? "Times New Roman" : "Times")
        #expect(commands.applyFontSize(28))
        if !commands.isBold { commands.toggleBold() }
        #expect(window.makeFirstResponder(nil))

        let updatedBody = note.body + " X"
        state.updateSelected(body: updatedBody)
        #expect(state.saveFeedback.state == .pending)
        try await settle { state.saveFeedback.state == .saving }
        try await Self.captureCompositedWindow(window, name: "notes-feedback-saving")
        try await settle { state.saveFeedback.showsSavedConfirmation }
        let persisted = root.appendingPathComponent(note.id.uuidString.lowercased() + ".md")
        #expect(try Data(contentsOf: persisted) == Data(updatedBody.utf8))
        try await Self.captureCompositedWindow(window, name: "notes-feedback-saved")

        let profile = UUID()
        func publishBanner() {
          state.publishAgentFeedback(AgentChangeFeedback(changeID: UUID(), noteID: note.id,
            noteTitle: note.title, actor: .integration(profileID: profile, displayName: "Codex"),
            resultingRevision: note.revision, createdAt: Date()))
        }
        for _ in 0..<3 { publishBanner() }
        let dismiss = "Dismiss Agent Activity update"
        let mute = "Do not show agent update banners again"
        try await settle { !Self.accessibilityElements(in: host, label: dismiss).isEmpty }
        #expect(state.agentBannerPresentation?.count == 3)
        try await Self.captureCompositedWindow(window, name: "notes-feedback-agent")
        for (label, file) in [("Undo", "undo"), (mute, "opt-out"), (dismiss, "dismiss")] {
          let frames = Self.accessibilityElements(in: host, label: label).compactMap { element -> CGRect? in
            guard element.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return nil }
            return (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
          }
          let frame = try #require(frames.min { $0.midY < $1.midY })
          try Self.movePointer(in: window, to: frame)
          try await Self.captureCompositedWindow(window, name: "notes-feedback-agent-hover-" + file)
        }
        try Self.press(dismiss, in: host)
        try await settle { Self.accessibilityElements(in: host, label: dismiss).isEmpty }
        publishBanner()
        try await settle { !Self.accessibilityElements(in: host, label: mute).isEmpty }
        try Self.press(mute, in: host)
        try await settle { !state.preferences.showAgentUpdateBanners }
        #expect(state.latestAgentFeedback?.noteID == note.id)
        try await state.saveNow().value
        let preferences = root.appendingPathComponent("preferences.json")
        let persistedPreferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: preferences))
        #expect(!persistedPreferences.showAgentUpdateBanners)
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLECK_TOOLBAR_WINDOW_CAPTURE"] == "1"))
    func darkNotesMenusExposeNativeCommandsInTheOwningWindow() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-notes-menus-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      let (workspace, note) = try Self.graphiteWorkspace()
      try await store.save(workspace: workspace, preferences: Self.graphitePreferences,
        trashedNotes: (1...9).map { Note(title: "Discarded fixture \($0)") })
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      state.agentActivityIndicator.receive(.began(requestID: UUID(), profileID: UUID()))
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      let commands = EditorCommands()
      let controller = NSHostingController(rootView: FleckThemeTestRoot(state: state) {
        NotesPanel(dictationRuntime: runtime, sizing: .container, editorCommands: commands)
          .frame(width: 686, height: 436)
      })
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 686, height: 436),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
      )
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let originalAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.hasShadow = false
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.contentViewController = controller
      let host = controller.view
      window.center()
      window.makeKeyAndOrderFront(nil)
      defer {
        window.contentViewController = nil
        window.close()
        NSApp.accessibilitySetValue(originalAX, forAttribute: enhancedAX)
      }
      do {
        try await Self.awaitKeyWindow(window)
        for _ in 0..<20 {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try #require(commands.textView)
        editor.isContinuousSpellCheckingEnabled = false
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        commands.applyFontFamily(NSFont(name: "Times", size: 28) == nil ? "Times New Roman" : "Times")
        #expect(commands.applyFontSize(28))
        if !commands.isBold { commands.toggleBold() }
        let storage = try #require(editor.textStorage)
        let bodyFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyParagraph = try #require(
          storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(bodyFont.fontName == "AvenirNext-Regular")
        #expect(bodyFont.pointSize == 17)
        #expect(bodyParagraph.minimumLineHeight == 27 && bodyParagraph.maximumLineHeight == 27)
        let titleFont = try #require(Self.titleField(in: host, title: note.title)?.font)
        #expect(titleFont.fontName == "AvenirNext-DemiBold")
        #expect(titleFont.pointSize == 20)
        #expect(window.makeFirstResponder(nil))
        try await Self.captureCompositedWindow(window, name: "more-matched-editor")
        let more = try #require(Self.accessibilityElements(in: host, label: "More formatting").first)
        let anchor = try #require(more.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        try Self.press("More formatting", in: host)
        let overflow = try await Self.visiblePopover(
          owning: window, previouslyVisible: visibleBefore, contains: "Tools / Insert"
        )
        let overflowContent = try #require(overflow.contentView)
        try #require(overflow !== window && overflow.parent === window)
        if let screen = window.screen {
          let visible = screen.visibleFrame
          if anchor.minY - visible.minY >= overflow.frame.height + 4 {
            #expect(abs(anchor.minY - overflow.frame.maxY - 4) <= 1,
              "More \(overflow.frame) should open four points below \(anchor)")
          } else if visible.maxY - anchor.maxY >= overflow.frame.height + 4 {
            #expect(abs(overflow.frame.minY - anchor.maxY - 4) <= 1,
              "More \(overflow.frame) should open four points above \(anchor)")
          }
          #expect(visible.insetBy(dx: -1, dy: -1).contains(overflow.frame))
          if anchor.maxX - visible.minX >= overflow.frame.width, anchor.maxX <= visible.maxX {
            #expect(abs(overflow.frame.maxX - anchor.maxX) <= 1,
              "Unclamped More \(overflow.frame) should align its trailing edge with the live More trigger \(anchor)")
          }
        }
        try await Self.captureCompositedWindow(window, name: "more-formatting-window")
        let beforeHover = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let originalSelection = editor.selectedRange()
        let originalBody = editor.string
        let paragraph = try #require(Self.accessibilityElements(in: overflowContent, label: "Paragraph").first)
        let paragraphFrame = try #require(paragraph.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let clock = ContinuousClock()
        let firstStarted = clock.now
        try Self.movePointer(in: overflow, to: paragraphFrame)
        let paragraphMenu = try await Self.visiblePopover(
          owning: overflow, previouslyVisible: beforeHover, contains: "Increase Indent"
        )
        let firstDuration = clock.now - firstStarted
        #expect(firstDuration < .milliseconds(145), "First branch hover took \(firstDuration)")
        try #require(paragraphMenu.parent === overflow)
        let paragraphContent = try #require(paragraphMenu.contentView)
        let alignment = try #require(Self.accessibilityElements(in: paragraphContent).first {
          Self.accessibilityName($0)?.hasPrefix("Alignment") == true
        })
        let alignmentFrame = try #require(alignment.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        if let visible = paragraphMenu.screen?.visibleFrame,
          paragraphFrame.maxY + 7 <= visible.maxY,
          paragraphFrame.maxY + 7 - paragraphMenu.frame.height >= visible.minY
        {
          #expect(abs(alignmentFrame.maxY - paragraphFrame.maxY) <= 1)
        }
        try Self.movePointer(in: paragraphMenu, to: alignmentFrame)
        let alignmentMenu = try await Self.visiblePopover(
          owning: paragraphMenu, previouslyVisible: beforeHover.union([ObjectIdentifier(paragraphMenu)]),
          contains: "Justified"
        )
        #expect(alignmentMenu.parent === paragraphMenu)
        #expect(editor.selectedRange() == originalSelection && editor.string == originalBody)
        try await Self.captureCompositedWindow(window, name: "more-alignment-hover-window")
        let lineSpacing = try #require(Self.accessibilityElements(in: paragraphContent).first {
          Self.accessibilityName($0)?.hasPrefix("Line Spacing") == true
        })
        let lineFrame = try #require(lineSpacing.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let alignmentContent = try #require(alignmentMenu.contentView)
        let justified = try #require(Self.accessibilityElements(in: alignmentContent, label: "Justified").first)
        let justifiedFrame = try #require(justified.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let alignmentPoint = CGPoint(x: paragraphMenu.frame.midX, y: alignmentFrame.midY)
        let opensLeft = alignmentMenu.frame.midX < paragraphMenu.frame.midX
        let targetX = opensLeft ? alignmentMenu.frame.maxX - 12 : alignmentMenu.frame.minX + 12
        let progress = (lineFrame.midY - alignmentPoint.y) / (justifiedFrame.midY - alignmentPoint.y)
        let diagonal = CGPoint(x: alignmentPoint.x + (targetX - alignmentPoint.x) * progress, y: lineFrame.midY)
        try #require(lineFrame.contains(diagonal) && (0..<1).contains(progress))
        try Self.movePointer(in: paragraphMenu, to: CGRect(origin: alignmentPoint, size: .zero))
        try await Task.sleep(for: .milliseconds(25))
        try Self.movePointer(in: paragraphMenu, to: CGRect(origin: diagonal, size: .zero))
        try await Task.sleep(for: .milliseconds(210))
        #expect(alignmentMenu.isVisible)
        try Self.movePointer(in: alignmentMenu, to: justifiedFrame)
        try await Task.sleep(for: .milliseconds(150))
        #expect(alignmentMenu.isVisible)

        try Self.movePointer(in: paragraphMenu, to: CGRect(origin: alignmentPoint, size: .zero))
        try await Task.sleep(for: .milliseconds(25))
        let beforeSwitch = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let switchStarted = clock.now
        let straight = CGPoint(x: alignmentPoint.x + (opensLeft ? -3 : 3), y: lineFrame.midY)
        try Self.movePointer(in: paragraphMenu, to: CGRect(origin: straight, size: .zero))
        let spacingMenu = try await Self.visiblePopover(
          owning: paragraphMenu, previouslyVisible: beforeSwitch, contains: "Double"
        )
        let switchDuration = clock.now - switchStarted
        #expect(switchDuration < .milliseconds(145), "Near-vertical sibling hover took \(switchDuration)")
        #expect(!alignmentMenu.isVisible && spacingMenu.parent === paragraphMenu)

        let beforeReverse = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let reverseStarted = clock.now
        try Self.movePointer(in: paragraphMenu, to: CGRect(origin: alignmentPoint, size: .zero))
        let reopenedAlignment = try await Self.visiblePopover(
          owning: paragraphMenu, previouslyVisible: beforeReverse, contains: "Justified"
        )
        let reverseDuration = clock.now - reverseStarted
        #expect(reverseDuration < .milliseconds(145), "Rapid reversal took \(reverseDuration)")
        #expect(!spacingMenu.isVisible)
        try await Task.sleep(for: .milliseconds(310))
        #expect(reopenedAlignment.isVisible && !spacingMenu.isVisible)
        print("MORE_HOVER first \(firstDuration); near-vertical sibling \(switchDuration); rapid reversal \(reverseDuration); diagonal retained Alignment")
        let menuKeyWindow = try #require(NSApp.keyWindow)
        try Self.postKey(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, in: menuKeyWindow)
        for _ in 0..<80 where reopenedAlignment.isVisible { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!reopenedAlignment.isVisible && paragraphMenu.isVisible)
        try Self.postKey("\u{1b}", code: 53, in: menuKeyWindow)
        for _ in 0..<80 where paragraphMenu.isVisible { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!paragraphMenu.isVisible && overflow.isVisible)
        try Self.postKey(String(UnicodeScalar(NSEndFunctionKey)!), code: 119, in: menuKeyWindow)
        try Self.postKey("\t", code: 48, modifiers: .shift, in: menuKeyWindow)
        try Self.postKey(" ", code: 49, in: menuKeyWindow)
        let keyboardParagraph = try await Self.visiblePopover(
          owning: overflow, previouslyVisible: beforeHover, contains: "Increase Indent"
        )
        #expect(keyboardParagraph.parent === overflow && NSApp.keyWindow === menuKeyWindow)
        let tools = try #require(Self.accessibilityElements(in: overflowContent, label: "Tools / Insert").first)
        let toolsFrame = try #require(tools.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let visibleBeforeTools = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        try Self.movePointer(in: overflow, to: toolsFrame)
        let toolsMenu = try await Self.visiblePopover(
          owning: overflow, previouslyVisible: visibleBeforeTools, contains: "Web Link…"
        )
        try #require(toolsMenu !== overflow && toolsMenu.parent === overflow)
        #expect(!keyboardParagraph.isVisible && !alignmentMenu.isVisible)
        try Self.press("Tools / Insert", in: overflowContent)
        #expect(toolsMenu.isVisible)
        try await Self.captureCompositedWindow(window, name: "more-tools-pointer-window")
        #expect(toolsMenu.frame.size == CGSize(width: 236, height: 199))
        let toolsContent = try #require(toolsMenu.contentView)
        let toolActions = ["Web Link…", "Link to Note…", "Find in Note", "Replace in Note", "Find Next", "Find Previous"]
        let exposedTools = Self.accessibilityElements(in: toolsContent).compactMap { element -> String? in
          guard element.responds(to: NSSelectorFromString("accessibilityPerformPress")),
            let label = Self.accessibilityName(element), toolActions.contains(label)
          else { return nil }
          return label
        }
        #expect(exposedTools == toolActions)
        try await Self.captureCompositedWindow(window, name: "native-tools-tracking")
        try await Self.captureCompositedWindow(toolsMenu, name: "native-tools-surface")
        let keyWindow = try #require(NSApp.keyWindow)
        try Self.postKey("\u{1b}", code: 53, in: keyWindow)
        for _ in 0..<80 where toolsMenu.isVisible { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!toolsMenu.isVisible)
        #expect(NSApp.keyWindow === keyWindow)
        func overflowIsOpen() -> Bool {
          overflow === window
            ? !Self.accessibilityElements(in: overflowContent, label: "Tools / Insert").isEmpty
            : overflow.isVisible
        }
        if overflowIsOpen() {
          try Self.press("More formatting", in: host)
          for _ in 0..<80 where overflowIsOpen() {
            try await Task.sleep(for: .milliseconds(25))
          }
          #expect(!overflowIsOpen())
        }
        try await Self.verifyNotesOptions(in: host, owner: window)
        func verifyBacklinks(containing label: String, capture name: String) async throws -> [String] {
          let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
          let button = try #require(Self.accessibilityElements(in: host, label: "Backlinks").first)
          let anchor = try #require(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          try Self.press("Backlinks", in: host)
          let popover = try await Self.visiblePopover(owning: window, previouslyVisible: visible, contains: label)
          #expect(popover.frame.midY < anchor.midY, "Backlinks \(popover.frame) should open below \(anchor)")
          try await Task.sleep(for: .milliseconds(280))
          try await Self.captureCompositedWindow(window, name: name)
          let content = try #require(popover.contentView)
          let labels = Self.accessibilityElements(in: content).compactMap { Self.accessibilityName($0) }
          try Self.press("Backlinks", in: host)
          for _ in 0..<80 where popover.isVisible { try await Task.sleep(for: .milliseconds(25)) }
          #expect(!popover.isVisible)
          return labels
        }
        let emptyLabels = try await verifyBacklinks(containing: "No notes link here", capture: "backlinks-empty-window")
        #expect(emptyLabels.contains("Linked from 0"))
        let development = workspace.folders[1].id
        let sources = workspace.notes.filter { $0.folderID == development }.prefix(3)
        let drafts = [
          ("Release checklist", "Check the final copy against ", "this note", ".", 3),
          ("Product brief", "Keep the ", "first release", " focused and quiet.", 1),
          ("Weekly journal", "A useful place to collect the ", "next steps", ".", 1),
        ]
        var withBacklinks = state.workspace
        for (index, pair) in zip(sources, drafts).enumerated() {
          let (source, (title, prefix, label, suffix, count)) = pair
          let link = NoteLinkFormatter.markdown(label: label, targetNoteID: note.id)
          let body = prefix + link + suffix + String(repeating: "\n" + link, count: count - 1)
          withBacklinks.updateNote(
            id: source.id, title: title, body: body, now: Date(timeIntervalSince1970: Double(300 - index))
          )
        }
        state.workspace = withBacklinks
        let populatedLabels = try await verifyBacklinks(containing: "Linked from 3", capture: "backlinks-populated-window")
        #expect(populatedLabels.contains { $0.contains("Release checklist") && $0.contains("3 references") })
        #expect(populatedLabels.contains { $0.contains("Product brief") && $0.contains("1 reference") })
        #expect(populatedLabels.contains { $0.contains("Weekly journal") && $0.contains("1 reference") })
        #expect(state.selectedNote?.id == note.id)
        #expect(state.selectedNote?.body == Self.graphiteBody)
        #expect(state.trashedNotes.count == 9)
        do {
          try await Self.verifyNotesHistory(window: window, host: host, runtime: runtime, note: note)
        } catch {
          Issue.record("Native Notes History verification failed: \(error)")
        }
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    @Test func darkToolsShortcutReturnsTypingToOwningWindow() async throws {
      let theme = FleckThemeSnapshot.resolve(colorTheme: .monochrome, mode: .dark,
        systemAppearance: .dark, reduceTransparency: false, increasedContrast: false)
      var query = ""
      let view = NotesToolsShortcutFixture(
        chrome: NotesSolidChrome(theme: theme, appearance: .solid),
        query: Binding(get: { query }, set: { query = $0 })
      )
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let originalAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      window.isReleasedWhenClosed = false
      let controller = NSHostingController(rootView: view)
      window.contentViewController = controller
      window.center()
      defer {
        window.contentViewController = nil
        window.close()
        NSApp.accessibilitySetValue(originalAX, forAttribute: enhancedAX)
      }
      try await Self.awaitKeyWindow(window)
      let host = controller.view
      for _ in 0..<10 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(25))
      }
      let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
      try Self.press("Tools", in: host)
      let direct = try await Self.visiblePopover(owning: window, previouslyVisible: before, contains: "Fixture command")
      #expect(direct.parent === window)
      try Self.postKey("f", code: 3, modifiers: [.command, .option], in: window)
      for _ in 0..<80 where direct.isVisible { try await Task.sleep(for: .milliseconds(25)) }
      #expect(!direct.isVisible && NSApp.keyWindow === window)
      for _ in 0..<80 where (window.firstResponder as? NSTextView)?.isFieldEditor != true {
        try await Task.sleep(for: .milliseconds(25))
      }
      try #require((window.firstResponder as? NSTextView)?.isFieldEditor == true)
      try Self.postKey("q", code: 12, in: window)
      for _ in 0..<80 where query.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
      #expect(query == "q")
    }

    private struct NotesToolsShortcutFixture: View {
      let chrome: NotesSolidChrome
      @Binding var query: String
      @FocusState private var hasFocus: Bool

      var body: some View {
        VStack {
          NotesToolsMenu(title: "Tools", chrome: chrome, actions: [NotesCascadeItem("Fixture command") {}]) {
            Text("Tools")
          }
          Button("Find fixture") { hasFocus = true }.keyboardShortcut("f", modifiers: [.command, .option])
          TextField("Query fixture", text: $query).focused($hasFocus)
        }
        .padding()
      }
    }

    @Test func darkPinnedCommandWClosesOnlyItsWindowWithoutTrashingTheNote() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-notes-command-w-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      let (workspace, note) = try Self.graphiteWorkspace()
      var preferences = Self.graphitePreferences
      preferences.confirmBeforeMovingNotesToTrash = false
      try await store.save(workspace: workspace, preferences: preferences)
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      func host(pinned: Bool) -> (NSWindow, EditorCommands) {
        let commands = EditorCommands()
        let view = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
          NotesPanel(dictationRuntime: runtime, isPinned: pinned, sizing: .container, editorCommands: commands)
            .frame(width: 686, height: 436)
        })
        let window = NSWindow(
          contentRect: .init(x: 60, y: pinned ? 90 : 140, width: 686, height: 436),
          styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return (window, commands)
      }
      let (unpinned, _) = host(pinned: false)
      let (pinned, pinnedCommands) = host(pinned: true)
      defer {
        for window in [pinned, unpinned] {
          window.contentView = nil
          window.close()
        }
      }
      do {
        try await Task.sleep(for: .milliseconds(250))
        try await Self.awaitKeyWindow(pinned)
        try #require(pinned.isKeyWindow && pinned.isVisible && unpinned.isVisible)
        let pinnedEditor = try #require(pinnedCommands.textView)
        #expect(pinned.makeFirstResponder(pinnedEditor))
        let command = try #require(NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [.command],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: pinned.windowNumber, context: nil,
          characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
      ))
        NSApp.postEvent(command, atStart: true)
        for _ in 0..<60 where pinned.isVisible {
          try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!pinned.isVisible)
        #expect(unpinned.isVisible)
        #expect(state.selectedNote?.id == note.id)
        #expect(state.workspace.notes.count == workspace.notes.count)
        #expect(state.trashedNotes.isEmpty)
        let reopened = try await store.loadSnapshot()
        let reopenedTrash = try await store.loadTrash()
        #expect(reopened.workspace.selectedNoteID == note.id)
        #expect(reopenedTrash.isEmpty)
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    @Test(arguments: [686, 460, 380])
    func darkNotesCaptureBannerKeepsCompleteSettingsActionsBelowCopy(width: Int) async throws {
      var activated: [String] = []
      let message = "Standard — Apple Speech needs Microphone access. Open System Settings to allow Fleck."
      let microphone = "Open Microphone Settings"
      let speech = "Open Speech Recognition Settings"
      let dismiss = "Dismiss dictation capture failure"
      let contents = NotesBannerNotice(
        icon: .system("mic"), message: message,
        actions: [.init(title: microphone) { activated.append(microphone) },
                  .init(title: speech) { activated.append(speech) }],
        onDismiss: .init(title: dismiss) { activated.append(dismiss) }
      )
      let size = NSSize(width: CGFloat(width), height: 236)
      let host = NSHostingView(rootView: VStack(spacing: 0) {
        contents.accessibilityLabel("Capture warning")
        Color.clear.frame(maxHeight: .infinity).layoutPriority(1)
      }
      .padding(11)
      .frame(width: size.width, height: size.height))
      let window = NSWindow(contentRect: .init(origin: .zero, size: size),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let previousAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      defer {
        window.close()
        NSApp.accessibilitySetValue(previousAX, forAttribute: enhancedAX)
      }
      try await Self.awaitKeyWindow(window)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(120))
      func frame(_ element: NSObject) throws -> CGRect {
        try #require((element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
      }
      let copy = try #require(Self.accessibilityElements(in: host, label: message).first)
      let copyFrame = try frame(copy)
      let banner = try #require(Self.accessibilityElements(in: host, label: "Capture warning").first)
      let bannerFrame = try frame(banner)
      #expect(bannerFrame.contains(copyFrame))
      let buttonPress = NSSelectorFromString("accessibilityPerformPress")
      for label in [microphone, speech] {
        let button = try #require(Self.accessibilityElements(in: host, label: label)
          .first { $0.responds(to: buttonPress) })
        let rect = try frame(button)
        #expect(rect.maxY <= copyFrame.minY + 2)
        #expect(bannerFrame.contains(rect))
        #expect(window.frame.insetBy(dx: 10, dy: 0).contains(rect))
        #expect(rect.height >= 28)
        #expect(rect.width >= (label as NSString).size(withAttributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]).width)
        _ = button.perform(buttonPress)
      }
      try Self.press(dismiss, in: host)
      #expect(activated == [microphone, speech, dismiss])
    }

    @Test(arguments: [460, 380])
    func dualDictationPermissionsUseOneRowAtDefaultAndFullRowsAtLargeType(width: Int) async throws {
      let title = "Dictation needs permission"
      let microphone = "Microphone Settings"
      let speech = "Speech Recognition Settings"
      let dismiss = "Dismiss dictation capture failure"
      let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let previousAX = NSApp.accessibilityAttributeValue(enhancedAX)
      NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
      defer { NSApp.accessibilitySetValue(previousAX, forAttribute: enhancedAX) }

      let scenarios: [(DynamicTypeSize, CGFloat?)] = [
        (.large, nil), (.accessibility5, nil), (.large, 24), (.large, 30),
      ]
      for (textSize, sharedPointSize) in scenarios {
        var activated: [String] = []
        let size = NSSize(width: CGFloat(width), height: 420)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
          NotesDictationPermissionsBanner(
            openMicrophone: { activated.append(microphone) },
            openSpeechRecognition: { activated.append(speech) },
            dismiss: { activated.append(dismiss) }
          )
          .accessibilityLabel("Dual permission banner")
          Color.clear.frame(maxHeight: .infinity).layoutPriority(1)
        }
        .padding(.horizontal, 11)
        .frame(width: size.width, height: size.height)
        .font(sharedPointSize.map { .system(size: $0) })
        .dynamicTypeSize(textSize))
        let window = NSWindow(contentRect: .init(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.awaitKeyWindow(window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))

        let press = NSSelectorFromString("accessibilityPerformPress")
        func element(_ label: String, action: Bool = false) throws -> NSObject {
          try #require(Self.accessibilityElements(in: host, label: label).first {
            !action || $0.responds(to: press)
          })
        }
        func frame(_ element: NSObject) throws -> CGRect {
          try #require((element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        }
        let bannerFrame = try frame(element("Dual permission banner"))
        let headingFrame = try frame(element(title))
        let closeFrame = try frame(element(dismiss, action: true))
        let mic = try element(microphone, action: true)
        let recognition = try element(speech, action: true)
        let micFrame = try frame(mic)
        let speechFrame = try frame(recognition)

        #expect(abs(bannerFrame.width - (size.width - 22)) <= 1)
        #expect(bannerFrame.contains(headingFrame) && bannerFrame.contains(closeFrame))
        #expect(bannerFrame.contains(micFrame) && bannerFrame.contains(speechFrame))
        #expect(headingFrame.maxX <= closeFrame.minX)
        #expect(micFrame.maxY <= headingFrame.minY)
        #expect(!micFrame.intersects(speechFrame))
        #expect(micFrame.height >= 28 && speechFrame.height >= 28)
        #expect(closeFrame.width >= 28 && closeFrame.height >= 28)
        if sharedPointSize == nil {
          #expect(abs(bannerFrame.height - 64) <= 1)
          #expect(micFrame.minY == speechFrame.minY)
          #expect(micFrame.maxX < speechFrame.minX)
        } else {
          #expect(micFrame.height > 28 && speechFrame.height > 28)
          #expect(micFrame.minY > speechFrame.maxY)
          #expect(micFrame.minX == speechFrame.minX)
          #expect(abs(micFrame.width - (bannerFrame.width - 20)) <= 1)
          #expect(micFrame.width == speechFrame.width)
          #expect(bannerFrame.height > 64)
        }

        _ = mic.perform(press)
        _ = recognition.perform(press)
        try Self.press(dismiss, in: host)
        #expect(activated == [microphone, speech, dismiss])
      }
    }

    @Test func darkFontPickerFiltersWithoutCommittingAndUsesNativeReturnAndEscape() throws {
      let theme = FleckThemeSnapshot.resolve(
        colorTheme: .monochrome, mode: .dark, systemAppearance: .dark,
        reduceTransparency: false, increasedContrast: false
      )
      let chrome = NotesSolidChrome(theme: theme, appearance: .solid)
      for (node, query, mixed) in [
        ("7PM-0", "", false), ("8I3-0", "times", false),
        ("8IL-0", "zzzz", false), ("8J0-0", "", true),
      ] {
        var commits: [String] = []
        var cancels = 0
        let picker = FontFamilyPickerController(
          currentFamily: "Times", isMixed: mixed, targetLabel: "Selected text",
          notesChrome: chrome, onCommit: { commits.append($0) }, onCancel: { cancels += 1 }
        )
        let height: CGFloat = query.isEmpty && !mixed ? 266 : 244
        let window = NSWindow(
          contentRect: .init(x: -10_000, y: -10_000, width: 280, height: height),
          styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = picker.view
        defer {
          window.contentView = nil
          window.close()
        }
        picker.searchField.stringValue = query
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(picker.preferredContentSize == NSSize(width: 280, height: height))
        window.setContentSize(picker.preferredContentSize)
        picker.view.layoutSubtreeIfNeeded()
        #expect(picker.view.bounds.size == NSSize(width: 280, height: height))
        if node == "7PM-0" {
          let scroll = try #require(picker.view.subviews.flatMap(\.subviews).compactMap { $0 as? NSScrollView }.first)
          let table = try #require(scroll.documentView as? NSTableView)
          #expect(table.rows(in: scroll.documentVisibleRect).location == 0)
          #expect(table.rows(in: scroll.documentVisibleRect).length >= 6)
          let bar = try #require(scroll.verticalScroller)
          let lastOrigin = table.bounds.height - scroll.contentView.bounds.height
          try #require(lastOrigin > 0)
          #expect(scroll.scrollerStyle == .overlay)
          for origin in [lastOrigin / 2, lastOrigin, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(abs(scroll.documentVisibleRect.minY - origin) <= 1)
            #expect(scroll.contentView.frame.maxX + 2 <= bar.frame.minX)
            #expect(abs(table.frame.width - scroll.contentView.bounds.width) <= 1)
            let knob = bar.rect(for: .knob)
            #expect(knob.width >= 8)
            #expect(bar.visibleRect.insetBy(dx: 2, dy: 1).contains(knob))
            #expect(scroll.bounds.maxX - bar.frame.maxX == 4)
          }
        }
        try Self.captureIfRequested(picker.view, name: node)
        #expect(commits.isEmpty)
        let keyResponder = NSTextView()
        if query == "times" {
          #expect(picker.control(
            picker.searchField, textView: keyResponder, doCommandBy: #selector(NSResponder.moveDown(_:))
          ))
          #expect(commits.isEmpty)
          #expect(picker.control(
            picker.searchField, textView: keyResponder, doCommandBy: #selector(NSResponder.insertNewline(_:))
          ))
          #expect(commits == ["Times New Roman"])
        } else if query == "zzzz" {
          #expect(picker.control(
            picker.searchField, textView: keyResponder, doCommandBy: #selector(NSResponder.insertNewline(_:))
          ))
          #expect(commits.isEmpty)
        }
        #expect(picker.control(
          picker.searchField, textView: keyResponder, doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(cancels == 1)
      }
    }

    @Test func darkFontSearchKeepsItsFieldEditorInsideTheNativeSearchTextRect() throws {
      let theme = FleckThemeSnapshot.resolve(
        colorTheme: .monochrome, mode: .dark, systemAppearance: .dark,
        reduceTransparency: false, increasedContrast: false
      )
      let picker = FontFamilyPickerController(
        currentFamily: "Times", isMixed: false, targetLabel: "Selected text",
        notesChrome: NotesSolidChrome(theme: theme, appearance: .solid),
        onCommit: { _ in }, onCancel: {}
      )
      let window = NSWindow(
        contentRect: .init(x: -10_000, y: -10_000, width: 280, height: 244),
        styleMask: .borderless, backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = picker.view
      defer {
        window.contentView = nil
        window.close()
      }
      let field = picker.searchField
      let sharedEditor = try #require(window.fieldEditor(true, for: nil) as? NSTextView)
      let previousCaretColor = sharedEditor.insertionPointColor
      field.stringValue = "times"
      picker.view.layoutSubtreeIfNeeded()
      let idleOutline = field.layer?.borderColor
      #expect(window.makeFirstResponder(field))
      let cell = try #require(field.cell as? NSSearchFieldCell)
      let editor = try #require(field.currentEditor() as? NSTextView)
      #expect(field.convert(editor.bounds, from: editor) == cell.searchTextRect(forBounds: field.bounds))
      #expect(editor.insertionPointColor == .white)
      #expect(field.layer?.borderColor != idleOutline)
      #expect(window.makeFirstResponder(nil))
      #expect(field.layer?.borderColor == idleOutline)
      #expect(sharedEditor.insertionPointColor == previousCaretColor)
    }

    @Test func restoringFromTrashKeepsTheActiveNoteInMemoryAndOnDisk() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-trash-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LocalStore(rootURL: root)
      let active = Note(title: "Editing")
      let discarded = Note(title: "Recovery fixture")
      _ = try await store.save(
        workspace: Workspace(notes: [active], selectedNoteID: active.id),
        preferences: AppPreferences(), trashedNotes: [discarded]
      )
      let state = AppState(store: store)
      await state.waitUntilInitialLoad()
      let entry = try #require(state.trashedNotes.first)
      let restore = try #require(state.restore(entry, selectsRestoredNote: false))
      await restore.value
      #expect(state.workspace.selectedNoteID == active.id)
      #expect(state.workspace.notes.contains { $0.id == discarded.id })
      #expect(state.trashedNotes.isEmpty)
      let reopened = try await store.loadSnapshot()
      #expect(reopened.workspace.selectedNoteID == active.id)
      #expect(reopened.workspace.notes.contains { $0.id == discarded.id })
      #expect(try await store.loadTrash().isEmpty)
    }

    @Test func refinedTrashUsesNativeOverlayAndKeepsTheActiveNote() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-trash-overlay-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let calendar = Calendar(identifier: .gregorian)
      let rows = [
        ("Early ideas", 10, 20, 8, 5),
        ("Reading notes", 11, 12, 16, 18),
        ("Launch plan", 11, 18, 9, 41),
      ]
      let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 11, day: 18, hour: 23, minute: 55
      )))
      let (workspace, active) = try Self.graphiteWorkspace()
      for (index, (title, month, day, hour, minute)) in rows.enumerated() {
        let date = try #require(calendar.date(from: DateComponents(
          year: 2026, month: month, day: day, hour: hour, minute: minute
        )))
        try await LocalStore(rootURL: root, now: { date }).save(
          workspace: workspace, preferences: Self.graphitePreferences,
          trashedNotes: [Note(title: title, folderID: workspace.folders[0].id)],
          generation: UInt64(index + 1)
        )
      }
      let store = LocalStore(rootURL: root, now: { now })
      let failure = FirstRestoreFailure()
      let state = AppState(store: store, restoreOperation: { row, workspace, preferences, generation in
        try await failure.check()
        return try await store.restore(row, into: workspace, preferences: preferences, generation: generation)
      })
      await state.waitUntilInitialLoad()
      state.agentActivityIndicator.receive(.began(requestID: UUID(), profileID: UUID()))
      let runtime = DictationRuntime(
        appState: state, applicationSupportURL: root, modifierMonitor: ReadyNotesFixtureMonitor()
      )
      let commands = EditorCommands()
      let host = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
        ZStack {
          NotesPanel(dictationRuntime: runtime, sizing: .container, editorCommands: commands)
            .disabled(true)
            .accessibilityHidden(true)
          TrashPanelOverlay(onDone: {}, now: { now })
        }
        .frame(width: 686, height: 436)
        .environment(\.locale, Locale(identifier: "en_US"))
      })
      let window = NSWindow(
        contentRect: .init(x: -10_000, y: -10_000, width: 686, height: 436),
        styleMask: .borderless, backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host
      window.orderBack(nil)
      defer {
        window.contentView = nil
        window.close()
      }
      func settle() async {
        for _ in 0..<40 {
          host.layoutSubtreeIfNeeded()
          await Task.yield()
        }
      }
      do {
        await settle()
        #expect(state.trashedNotes.map(\.note.title) == rows.reversed().map { $0.0 })
        try Self.captureIfRequested(host, name: "9OD-0")
        state.saveError = "Unrelated editor error"
        await state.refreshTrash()
        #expect(state.saveError == "Unrelated editor error")
        #expect(state.trashUpdateError == nil)
        let first = try #require(state.trashedNotes.first)
        let failed = try #require(state.restore(first, selectsRestoredNote: false))
        await failed.value
        #expect(state.trashUpdateError == "The file couldn’t be saved.")
        #expect(state.trashedNotes.contains { $0.id == first.id })
        await settle()
        try Self.captureIfRequested(host, name: "A7N-0")
        for (index, entry) in state.trashedNotes.enumerated() {
          let task = try #require(state.restore(entry, selectsRestoredNote: false))
          await task.value
          await settle()
          if index == 0 { try Self.captureIfRequested(host, name: "9UZ-0") }
        }
        #expect(state.trashedNotes.isEmpty)
        #expect(state.trashUpdateError == nil)
        #expect(state.workspace.selectedNoteID == active.id)
        try Self.captureIfRequested(host, name: "A1F-0")
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
    }

    private actor FirstRestoreFailure {
      private var shouldFail = true

      func check() throws {
        guard shouldFail else { return }
        shouldFail = false
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
          NSLocalizedDescriptionKey: "The file couldn’t be saved."
        ])
      }
    }

    private static func selectedTabSource(in view: NSView, noteID: UUID) -> ReorderSourceHostingView? {
      if let source = view as? ReorderSourceHostingView, source.noteID == noteID { return source }
      return view.subviews.lazy.compactMap { selectedTabSource(in: $0, noteID: noteID) }.first
    }

    private static func bitmap(of view: NSView) throws -> NSBitmapImageRep {
      let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ))
      bitmap.size = view.bounds.size
      view.displayIfNeeded()
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return bitmap
    }

    private static func evidenceDirectory() throws -> URL? {
      let environment = ProcessInfo.processInfo.environment
      guard environment["FLECK_NATIVE_CAPTURE_QA"] == "1",
        let path = environment["FLECK_EDITOR_EVIDENCE_DIR"]
      else { return nil }
      let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      let run = folder.deletingLastPathComponent()
      try #require(folder.lastPathComponent == "evidence")
      for (key, leaf) in [("HOME", "home"), ("TMPDIR", "tmp")] {
        let value = try #require(environment[key])
        let directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        try #require(directory.path == run.appendingPathComponent(leaf).path)
      }
      for directory in [run, folder, run.appendingPathComponent("home"), run.appendingPathComponent("tmp")] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(values.isDirectory == true && values.isSymbolicLink == false)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        try #require(mode.intValue & 0o777 == 0o700)
      }
      return folder
    }

    private static func captureIfRequested(_ view: NSView, name: String) throws {
      guard let folder = try evidenceDirectory() else { return }
      try writeBitmap(bitmap(of: view), in: folder, name: name)
    }

    private static func writeBitmap(_ bitmap: NSBitmapImageRep, in folder: URL, name: String) throws {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: folder.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
    }

    private static func captureCompositedWindow(_ window: NSWindow, name: String) async throws {
      let destination = try evidenceDirectory()
      try await captureCompositedWindow(
        number: CGWindowID(window.windowNumber), size: window.frame.size,
        folder: try #require(destination), name: name
      )
    }

    private nonisolated static func captureCompositedWindow(
      number: CGWindowID, size: CGSize, folder: URL, name: String
    ) async throws {
      guard #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(3))
      repeat {
        try await Task.sleep(for: .milliseconds(70))
        let content = try await SCShareableContent.currentProcess
        if let own = content.windows.first(where: {
          $0.windowID == number && $0.isOnScreen
            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }) {
          let filter = SCContentFilter(desktopIndependentWindow: own)
          let image: CGImage
          if #available(macOS 26, *) {
            let config = SCScreenshotConfiguration()
            config.showsCursor = false
            config.ignoreShadows = true
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            image = try #require(output.sdrImage)
            if name.hasPrefix("native-") {
              config.includeChildWindows = false
              let control = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
              try writeCapture(try #require(control.sdrImage), in: folder, name: name + "-control")
            }
          } else {
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
          }
          let frames = content.windows.filter {
            $0.isOnScreen && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
          }.map { "\($0.windowID):\($0.frame)" }
          print("COMPOSITOR \(name): bounds=\(filter.contentRect), scale=\(filter.pointPixelScale), output=\(image.width)×\(image.height), windows=\(frames)")
          try writeCapture(image, in: folder, name: name)
          if #available(macOS 26, *), filter.pointPixelScale > 1 {
            let config = SCScreenshotConfiguration()
            config.width = Int((Double(image.width) / Double(filter.pointPixelScale)).rounded(.up))
            config.height = Int((Double(image.height) / Double(filter.pointPixelScale)).rounded(.up))
            config.showsCursor = false
            config.ignoreShadows = true
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            try writeCapture(try #require(output.sdrImage), in: folder, name: name + "-1x")
          }
          return
        }
      } while clock.now < deadline
      throw CocoaError(.featureUnsupported)
    }

    private nonisolated static func writeCapture(_ image: CGImage, in folder: URL, name: String) throws {
      let buffer = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
      try (buffer as Data).write(to: folder.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
    }

    private static func accessibilityString(_ element: NSObject, property: String) -> String? {
      let getter = NSSelectorFromString(property)
      guard element.responds(to: getter) else { return nil }
      return element.perform(getter)?.takeUnretainedValue() as? String
    }

    private static func accessibilityElements(in root: NSObject, label: String? = nil) -> [NSObject] {
      let children = NSSelectorFromString("accessibilityChildren")
      var seen: Set<ObjectIdentifier> = []
      func find(in element: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
        let name = accessibilityName(element)
        let match = name != nil && (label == nil || name == label) ? [element] : []
        guard element.responds(to: children),
          let items = element.perform(children)?.takeUnretainedValue() as? [NSObject]
        else { return match }
        return match + items.flatMap { find(in: $0) }
      }
      return find(in: root)
    }

    private static func accessibilityName(_ element: NSObject) -> String? {
      let isStaticText = accessibilityString(element, property: "accessibilityRole")
        == NSAccessibility.Role.staticText.rawValue
      for property in isStaticText ? ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
        : ["accessibilityLabel", "accessibilityTitle"]
      {
        let getter = NSSelectorFromString(property)
        guard element.responds(to: getter),
          let value = element.perform(getter)?.takeUnretainedValue() else { continue }
        if let text = value as? String, !text.isEmpty { return text }
        if let text = value as? NSAttributedString, !text.string.isEmpty { return text.string }
      }
      return nil
    }

    private static func awaitKeyWindow(_ window: NSWindow) async throws {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      for _ in 0..<60 {
        if window.isKeyWindow { return }
        try await Task.sleep(for: .milliseconds(25))
      }
      try #require(window.isKeyWindow, "Fixture has no key window (app active: \(NSApp.isActive))")
    }

    private static func titleField(in view: NSView, title: String) -> NSTextField? {
      if let field = view as? NSTextField, field.stringValue == title, field.isEditable { return field }
      return view.subviews.lazy.compactMap { titleField(in: $0, title: title) }.first
    }

    private static func movePointer(in window: NSWindow, to screenFrame: CGRect) throws {
      let point = window.convertPoint(fromScreen: CGPoint(x: screenFrame.midX, y: screenFrame.midY))
      let event = try #require(NSEvent.mouseEvent(
        with: .mouseMoved, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 0, pressure: 0
      ))
      window.acceptsMouseMovedEvents = true
      NSApp.postEvent(event, atStart: true)
    }

    private static func postKey(
      _ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws {
      let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
      ))
      NSApp.postEvent(event, atStart: false)
    }

    private static func press(_ label: String, in root: NSObject) throws {
      let element = try #require(accessibilityElements(in: root, label: label).first)
      let action = NSSelectorFromString("accessibilityPerformPress")
      try #require(element.responds(to: action))
      _ = element.perform(action)
    }

    private static func visiblePopover(
      owning window: NSWindow, previouslyVisible: Set<ObjectIdentifier>, contains label: String
    ) async throws -> NSWindow {
      func candidates() -> [NSWindow] {
        ((window.childWindows ?? []) + NSApp.windows).filter {
          $0.isVisible && !previouslyVisible.contains(ObjectIdentifier($0))
        }
      }
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      repeat {
        if let child = (candidates() + [window]).first(where: { child in
          guard let view = child.contentView else { return false }
          return !accessibilityElements(in: view, label: label).isEmpty
        }) { return child }
        try await Task.sleep(for: .milliseconds(25))
      } while clock.now < deadline
      let labels = candidates().compactMap(\.contentView).flatMap { accessibilityElements(in: $0) }
        .compactMap { accessibilityName($0) }
      Issue.record("No new visible window contains \(label); found \(labels)")
      throw CocoaError(.featureUnsupported)
    }

    private static func verifyNotesOptions(in root: NSObject, owner: NSWindow) async throws {
      let actions = [
        "Add File Shortcut…", "Import Text or Markdown…", "Export Markdown…", "Export Plain Text…",
        "Export Rich Text…", "Trash…", "Dictation History", "Agent Activity",
      ]
      let responder = owner.firstResponder
      for _ in 0..<3 {
        let menu = try await trackNativeNotesOptions(in: root, owner: owner)
        let visibleItems = menu.items.filter { !$0.isHidden }
        #expect(visibleItems.filter { !$0.isSeparatorItem }.map(\.title) == actions)
        #expect(visibleItems.filter(\.isSeparatorItem).count == 3)
        #expect(NSApp.keyWindow === owner)
        #expect(owner.firstResponder === responder)
      }
    }

    @MainActor private final class NativeOptionsProbe: NSObject {
      let owner: NSWindow
      let action: String?
      var menu: NSMenu?
      var didEndTracking = false

      init(owner: NSWindow, action: String?) {
        self.owner = owner
        self.action = action
      }

      @objc func beginTracking(_ notification: Notification) {
        guard owner.isKeyWindow,
          let menu = notification.object as? NSMenu,
          menu.items.contains(where: { $0.title == "Import Text or Markdown…" })
        else { return }
        self.menu = menu
        let drive = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, let menu = self.menu, !self.didEndTracking else { return }
            defer { menu.cancelTracking() }
            if let action = self.action,
              let index = menu.items.firstIndex(where: { $0.title == action && $0.isEnabled })
            {
              menu.performActionForItem(at: index)
            } else if let action = self.action {
              Issue.record("Native Options does not expose enabled action \(action)")
            }
          }
        }
        RunLoop.main.add(drive, forMode: .eventTracking)
        RunLoop.main.add(drive, forMode: .common)
      }

      @objc func endTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu, self.menu === menu {
          didEndTracking = true
        }
      }
    }

    private static func trackNativeNotesOptions(
      in root: NSObject, owner: NSWindow, choosing action: String? = nil
    ) async throws -> NSMenu {
      let probe = NativeOptionsProbe(owner: owner, action: action)
      let center = NotificationCenter.default
      center.addObserver(probe, selector: #selector(NativeOptionsProbe.beginTracking(_:)),
        name: NSMenu.didBeginTrackingNotification, object: nil)
      center.addObserver(probe, selector: #selector(NativeOptionsProbe.endTracking(_:)),
        name: NSMenu.didEndTrackingNotification, object: nil)
      let watchdog = Timer(timeInterval: 1, repeats: false) { _ in
        MainActor.assumeIsolated {
          guard !probe.didEndTracking, owner.isKeyWindow else { return }
          if let menu = probe.menu { menu.cancelTracking() }
          else if let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
          ) {
            NSApp.postEvent(escape, atStart: true)
          }
        }
      }
      RunLoop.main.add(watchdog, forMode: .eventTracking)
      RunLoop.main.add(watchdog, forMode: .common)
      defer {
        watchdog.invalidate()
        center.removeObserver(probe)
      }
      try press("Options", in: root)
      let deadline = ContinuousClock.now + .seconds(2)
      while !probe.didEndTracking && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      try #require(probe.didEndTracking, "The native Notes Options menu did not finish tracking")
      return try #require(probe.menu)
    }

    private static func verifyNotesHistory(
      window: NSWindow, host: NSObject, runtime: DictationRuntime, note: Note
    ) async throws {
      let history = runtime.historyController
      let timestamp = Date()
      let saved = DictationHistoryRecord(
        id: UUID(), mode: .smartCapture, engine: .standard,
        startedAt: timestamp.addingTimeInterval(-10), completedAt: timestamp,
        rawTranscript: "um ship the first beta on friday check the notes before sharing",
        cleanedTranscript: "Ship the first beta on Friday. Check the notes before sharing.",
        cleanupOutcome: .cleaned, destination: .init(noteID: note.id, title: note.title),
        insertionOutcome: .saved
      )
      let fallback = DictationHistoryRecord(
        id: UUID(), mode: .smartCapture, engine: .standard,
        startedAt: timestamp.addingTimeInterval(-100), completedAt: timestamp.addingTimeInterval(-90),
        rawTranscript: "Check the launch notes and make sure the download link is correct.",
        cleanupOutcome: .usedRaw, insertionOutcome: .unsaved
      )
      try #require(await history.save(saved))
      try #require(await history.save(fallback))
      let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
      _ = try await trackNativeNotesOptions(in: host, owner: window, choosing: "Dictation History")
      let sheet = try await visiblePopover(owning: window, previouslyVisible: visible, contains: "Done")
      defer { try? press("Done", in: sheet.contentView ?? NSView()) }
      let content = try #require(sheet.contentView)
      try await captureCompositedWindow(sheet, name: "history-saved-and-raw")
      #expect(!accessibilityElements(in: content, label: "Raw fallback").isEmpty)
      #expect(!accessibilityElements(in: content, label: "Cleaned").isEmpty)
      try press("Clear History", in: content)
      try await captureCompositedWindow(sheet, name: "history-clear-confirmation")
      #expect(!accessibilityElements(in: content, label: "Clear all dictation history?").isEmpty)
      try press("Cancel", in: content)
      #expect(history.records.count == 2)
      try await Task.sleep(for: .milliseconds(120))
      try press("Clear History", in: content)
      try await Task.sleep(for: .milliseconds(120))
      try press("Clear History", in: content)
      let deadline = ContinuousClock.now + .seconds(2)
      while !history.records.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(history.records.isEmpty)
      try await captureCompositedWindow(sheet, name: "history-empty")
      #expect(!accessibilityElements(in: content, label: "No Dictation History").isEmpty)
    }

  }

  private final class NotesEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }

  @MainActor
  private final class ReadyNotesFixtureMonitor: ModifierKeyMonitoring {
    var transitionHandler: ((ModifierKeyTransition) -> Void)?
    var stateHandler: ((ModifierMonitorState) -> Void)?
    var accessGranted: Bool { true }

    func start() throws { stateHandler?(.running) }
    func stop() { stateHandler?(.stopped) }
    func requestAccess() -> Bool { true }
  }
#endif
