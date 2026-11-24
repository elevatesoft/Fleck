#if os(macOS)
  import AppKit
  import FleckCore
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
      let host = NSHostingView(rootView: FleckThemeTestRoot(state: state) {
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
      window.contentView = host
      window.center()
      window.makeKeyAndOrderFront(nil)
      defer {
        window.contentView = nil
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
        if overflow !== window, let screen = window.screen,
          anchor.minY - screen.visibleFrame.minY > overflow.frame.height
        {
          #expect(overflow.frame.midY < anchor.midY, "More \(overflow.frame) should open below \(anchor)")
        }
        do {
          try await Task.sleep(for: .milliseconds(280))
          try await Self.captureCompositedWindow(window, name: "more-formatting-window")
          let tools = try #require(Self.accessibilityElements(in: overflowContent, label: "Tools / Insert").first)
          let toolsFrame = try #require(tools.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          try Self.movePointer(in: overflow, to: toolsFrame)
          try await Task.sleep(for: .milliseconds(180))
          try await Self.captureCompositedWindow(window, name: "more-tools-pointer-window")
        } catch {
          Issue.record("Could not capture the open More popover: \(error)")
        }
        try await Self.expectMenu(
          in: overflowContent, label: "Tools / Insert",
          actions: ["Web Link…", "Link to Note…", "Find in Note", "Replace in Note", "Find Next", "Find Previous"],
          screenshot: (window, "native-tools-tracking", 0)
        )
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
        try await Self.expectMenu(
          in: host, label: "Options",
          actions: ["Add File Shortcut…", "Import Text or Markdown…", "Export Markdown…", "Export Plain Text…",
            "Export Rich Text…", "Trash…", "Dictation History", "Agent Activity",
            AgentCapabilityPresentation.manageAgentAccessTitle],
          screenshot: (window, "native-options-tracking", 3)
        )
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
      } catch {
        await runtime.shutdown()
        throw error
      }
      await runtime.shutdown()
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
      let folder = try #require(destination)
      guard #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
      let number = CGWindowID(window.windowNumber)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(3))
      repeat {
        try await Task.sleep(for: .milliseconds(70))
        let content = try await SCShareableContent.currentProcess
        if let own = content.windows.first(where: { $0.windowID == number && $0.isOnScreen }) {
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
              try writeBitmap(NSBitmapImageRep(cgImage: try #require(control.sdrImage)), in: folder, name: name + "-control")
            }
          } else {
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
          }
          let frames = content.windows.filter {
            $0.isOnScreen && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
          }.map { "\($0.windowID):\($0.frame)" }
          print("COMPOSITOR \(name): bounds=\(filter.contentRect), scale=\(filter.pointPixelScale), output=\(image.width)×\(image.height), windows=\(frames)")
          try writeBitmap(NSBitmapImageRep(cgImage: image), in: folder, name: name)
          if #available(macOS 26, *), filter.pointPixelScale > 1 {
            let config = SCScreenshotConfiguration()
            config.width = Int((Double(image.width) / Double(filter.pointPixelScale)).rounded(.up))
            config.height = Int((Double(image.height) / Double(filter.pointPixelScale)).rounded(.up))
            config.showsCursor = false
            config.ignoreShadows = true
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            try writeBitmap(NSBitmapImageRep(cgImage: try #require(output.sdrImage)), in: folder, name: name + "-1x")
          }
          return
        }
      } while clock.now < deadline
      Issue.record("The isolated Notes window did not become capturable")
      throw CocoaError(.featureUnsupported)
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

    private static func expectMenu(
      in root: NSObject, label: String, actions: [String], screenshot: (NSWindow, String, Int)
    ) async throws {
      let observed = MenuTrackingObservation(firstExpectedTitle: actions[0]) { menu, observation in
        let (owner, name, downCount) = screenshot
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        for _ in 0..<downCount {
          if let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
            context: nil, characters: down, charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125
          ) {
            NSApp.postEvent(key, atStart: false)
          }
        }
        let timeout = Timer(timeInterval: 1.5, target: observation,
          selector: #selector(MenuTrackingObservation.stopTracking), userInfo: nil, repeats: false)
        RunLoop.main.add(timeout, forMode: .eventTracking)
        RunLoop.main.add(timeout, forMode: .default)
        Task {
          defer {
            timeout.invalidate()
            observation.stopTracking()
          }
          do {
            try await Task.sleep(for: .milliseconds(230))
            let highlighted = menu.highlightedItem?.title ?? "none"
            guard observation.trackingMenu != nil else {
              print("MENU_PROBE \(name): capture task could not run during native menu tracking")
              return
            }
            try await captureCompositedWindow(owner, name: name)
            print("MENU_PROBE \(name): highlighted=\(highlighted), item icons=\(menu.items.filter { $0.image != nil }.count)")
          } catch {
            print("MENU_PROBE \(name): \(error)")
          }
        }
      }
      NotificationCenter.default.addObserver(
        observed, selector: #selector(MenuTrackingObservation.didBeginTracking(_:)),
        name: NSMenu.didBeginTrackingNotification, object: nil
      )
      defer { NotificationCenter.default.removeObserver(observed) }
      try press(label, in: root)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      while (observed.titles == nil || observed.trackingMenu != nil) && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(observed.titles == actions, "Unexpected menu action order for \(label)")
    }
  }

  @MainActor
  private final class MenuTrackingObservation: NSObject {
    let firstExpectedTitle: String
    let onStart: (NSMenu, MenuTrackingObservation) -> Void
    var titles: [String]?
    private(set) var trackingMenu: NSMenu?

    init(firstExpectedTitle: String, onStart: @escaping (NSMenu, MenuTrackingObservation) -> Void) {
      self.firstExpectedTitle = firstExpectedTitle
      self.onStart = onStart
    }

    @objc func didBeginTracking(_ notification: Notification) {
      guard let menu = notification.object as? NSMenu else { return }
      let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
      guard titles.contains(firstExpectedTitle) else { return }
      self.titles = titles
      trackingMenu = menu
      onStart(menu, self)
    }

    @objc func stopTracking() {
      let menu = trackingMenu
      trackingMenu = nil
      menu?.cancelTrackingWithoutAnimation()
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
