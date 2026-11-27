#if os(macOS)
  import AppKit
  import Combine
  import FleckCore
  import SwiftUI

  @MainActor
  final class NoteLinkPickerController: ObservableObject {
    typealias SearchOperation = @MainActor (
      String,
      [Note],
      Int
    ) async -> [WorkspaceSearchResult]

    enum HighlightDirection {
      case up
      case down
    }

    static let recentNotesLimit = 8

    @Published private(set) var isPresented = false
    @Published var query = ""
    @Published private(set) var results: [WorkspaceSearchResult] = []
    @Published private(set) var highlightedNoteID: UUID?
    @Published private(set) var isShowingRecentNotes = false

    private let searchOperation: SearchOperation
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    @Published private var resultGeneration: UInt64?
    private var resultsQuery: String?
    private weak var hostingWindow: NSWindow?
    private var focusOrigin: NoteLinkPickerFocusOrigin?
    private(set) var sourceNoteID: UUID?
    private(set) var sourceRevision: UInt64?
    private(set) var replacementRange: NSRange?
    private var canPresent: @MainActor () -> Bool = { true }
    private var hasActivatedCurrentPresentation = false

    init(
      searchOperation: @escaping SearchOperation = { query, notes, limit in
        await WorkspaceSearchEngine().search(query: query, in: notes, limit: limit)
      }
    ) {
      self.searchOperation = searchOperation
    }

    var resultsAreCurrent: Bool {
      resultGeneration == searchGeneration && resultsQuery == query
    }

    var hasQuery: Bool {
      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isUpdatingResults: Bool {
      isPresented && hasQuery && !resultsAreCurrent
    }

    var resultCountAccessibilityValue: String {
      let countDescription: String
      switch results.count {
      case 0: countDescription = "No results"
      case 1: countDescription = "1 result"
      default: countDescription = "\(results.count) results"
      }
      guard isUpdatingResults else { return countDescription }
      guard !results.isEmpty else { return "Updating search results" }
      return "Updating search results; \(countDescription)"
    }

    var presentedSourceNoteID: UUID? { sourceNoteID }
    var presentedSourceRevision: UInt64? { sourceRevision }
    var presentedReplacementRange: NSRange? { replacementRange }

    func setPresentationGuard(_ presentationGuard: @escaping @MainActor () -> Bool) {
      canPresent = presentationGuard
    }

    func setHostingWindow(_ window: NSWindow?) {
      hostingWindow = window
    }

    func present(
      sourceNoteID: UUID,
      replacementRange: NSRange,
      sourceRevision: UInt64
    ) {
      guard !isPresented, canPresent() else { return }
      cancelSearch()
      searchGeneration &+= 1
      focusOrigin = NoteLinkPickerFocusOrigin.capture(preferredWindow: hostingWindow)
      self.sourceNoteID = sourceNoteID
      self.sourceRevision = sourceRevision
      self.replacementRange = replacementRange
      query = ""
      results = []
      highlightedNoteID = nil
      resultGeneration = nil
      resultsQuery = nil
      isShowingRecentNotes = false
      hasActivatedCurrentPresentation = false
      isPresented = true
    }

    func dismiss() {
      guard isPresented || focusOrigin != nil else { return }
      cancelSearch()
      searchGeneration &+= 1
      isPresented = false
      query = ""
      results = []
      highlightedNoteID = nil
      resultGeneration = nil
      resultsQuery = nil
      isShowingRecentNotes = false
      sourceNoteID = nil
      sourceRevision = nil
      replacementRange = nil
      hasActivatedCurrentPresentation = false
      let origin = focusOrigin
      focusOrigin = nil
      origin?.restore()
      if let origin {
        Task { @MainActor in
          for _ in 0..<12 {
            await Task.yield()
            if origin.restore() { break }
          }
        }
      }
    }

    func setQuery(_ query: String, notes: [Note]) {
      self.query = query
      refresh(in: notes)
    }

    func setQuery(_ query: String, in notes: [Note]) {
      setQuery(query, notes: notes)
    }

    func refresh(in notes: [Note]) {
      cancelSearch()
      searchGeneration &+= 1
      let generation = searchGeneration
      resultGeneration = nil
      let requestQuery = query
      let sourceID = sourceNoteID
      let candidates = notes.filter { $0.id != sourceID }

      guard isPresented else {
        results = []
        highlightedNoteID = nil
        isShowingRecentNotes = false
        return
      }

      guard hasQuery else {
        isShowingRecentNotes = true
        apply(Self.recentResults(in: candidates), generation: generation, query: requestQuery)
        return
      }

      isShowingRecentNotes = false
      let operation = searchOperation
      searchTask = Task { @MainActor [weak self] in
        let results = await operation(requestQuery, candidates, 50)
        guard let self,
          !Task.isCancelled,
          self.isPresented,
          self.searchGeneration == generation,
          self.query == requestQuery
        else { return }
        self.apply(results, generation: generation, query: requestQuery)
      }
    }

    func moveHighlight(_ direction: HighlightDirection) {
      guard resultsAreCurrent, !results.isEmpty else { return }
      guard let highlightedNoteID,
        let currentIndex = results.firstIndex(where: { $0.noteID == highlightedNoteID })
      else {
        self.highlightedNoteID = direction == .up ? results.last?.noteID : results.first?.noteID
        return
      }
      let nextIndex: Int
      switch direction {
      case .up: nextIndex = max(0, currentIndex - 1)
      case .down: nextIndex = min(results.count - 1, currentIndex + 1)
      }
      self.highlightedNoteID = results[nextIndex].noteID
    }

    func highlight(_ noteID: UUID) {
      guard results.contains(where: { $0.noteID == noteID }) else { return }
      highlightedNoteID = noteID
    }

    func isHighlighted(_ noteID: UUID) -> Bool {
      highlightedNoteID == noteID
    }

    @discardableResult
    func activateHighlighted(
      currentNoteIDs: Set<UUID>,
      currentSourceNoteID: UUID?,
      currentSourceRevision: UInt64?,
      activate: (UUID, NSRange) -> Void
    ) -> Bool {
      guard isPresented,
        !hasActivatedCurrentPresentation,
        resultsAreCurrent,
        let noteID = highlightedNoteID,
        currentNoteIDs.contains(noteID),
        let replacementRange,
        results.contains(where: { $0.noteID == noteID })
      else { return false }

      guard sourceNoteID == currentSourceNoteID,
        sourceRevision == currentSourceRevision
      else {
        dismiss()
        return false
      }

      hasActivatedCurrentPresentation = true
      dismiss()
      activate(noteID, replacementRange)
      return true
    }

    @discardableResult
    func activateResult(
      _ noteID: UUID,
      currentNoteIDs: Set<UUID>,
      currentSourceNoteID: UUID?,
      currentSourceRevision: UInt64?,
      activate: (UUID, NSRange) -> Void
    ) -> Bool {
      guard resultsAreCurrent,
        currentNoteIDs.contains(noteID),
        results.contains(where: { $0.noteID == noteID })
      else { return false }
      highlight(noteID)
      return activateHighlighted(
        currentNoteIDs: currentNoteIDs,
        currentSourceNoteID: currentSourceNoteID,
        currentSourceRevision: currentSourceRevision,
        activate: activate
      )
    }

    @discardableResult
    func handleKey(
      _ key: KeyEquivalent,
      currentNoteIDs: Set<UUID> = [],
      currentSourceNoteID: UUID? = nil,
      currentSourceRevision: UInt64? = nil,
      activate: (UUID, NSRange) -> Void = { _, _ in }
    ) -> Bool {
      switch key {
      case .upArrow:
        moveHighlight(.up)
        return true
      case .downArrow:
        moveHighlight(.down)
        return true
      case .return:
        _ = activateHighlighted(
          currentNoteIDs: currentNoteIDs,
          currentSourceNoteID: currentSourceNoteID,
          currentSourceRevision: currentSourceRevision,
          activate: activate
        )
        return true
      case .escape:
        dismiss()
        return true
      default:
        return false
      }
    }

    static func recentResults(
      in notes: [Note],
      limit: Int = recentNotesLimit
    ) -> [WorkspaceSearchResult] {
      guard limit > 0 else { return [] }
      return notes
        .sorted { lhs, rhs in
          if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
          return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        .prefix(limit)
        .map { note in
          WorkspaceSearchResult(
            noteID: note.id,
            displayTitle: note.displayTitle,
            snippet: recentPreview(of: note.body),
            match: WorkspaceSearchMatch(field: .title, location: NSNotFound, length: 0),
            score: 0
          )
        }
    }

    private static let recentPreviewLimit = 120

    private static func recentPreview(of body: String) -> String {
      let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard collapsed.count > recentPreviewLimit else { return collapsed }
      return String(collapsed.prefix(recentPreviewLimit)) + "…"
    }

    private func apply(_ results: [WorkspaceSearchResult], generation: UInt64, query: String) {
      let results = Array(results.prefix(50))
      let previousHighlight = highlightedNoteID
      resultsQuery = query
      resultGeneration = generation
      self.results = results
      if let previousHighlight, results.contains(where: { $0.noteID == previousHighlight }) {
        highlightedNoteID = previousHighlight
      } else {
        highlightedNoteID = results.first?.noteID
      }
    }

    private func cancelSearch() {
      searchTask?.cancel()
      searchTask = nil
    }

    deinit {
      searchTask?.cancel()
    }
  }

  @MainActor
  private final class NoteLinkPickerFocusOrigin {
    weak var window: NSWindow?
    weak var responder: NSResponder?
    weak var fieldEditorOwner: NSView?
    let fieldEditorSelection: NSRange?

    private init(
      window: NSWindow,
      responder: NSResponder,
      fieldEditorOwner: NSView? = nil,
      fieldEditorSelection: NSRange? = nil
    ) {
      self.window = window
      self.responder = responder
      self.fieldEditorOwner = fieldEditorOwner
      self.fieldEditorSelection = fieldEditorSelection
    }

    static func capture(preferredWindow: NSWindow?) -> NoteLinkPickerFocusOrigin? {
      guard let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
        let responder = window.firstResponder
      else { return nil }
      guard let fieldEditor = responder as? NSTextView else {
        return NoteLinkPickerFocusOrigin(window: window, responder: responder)
      }
      let owner = (fieldEditor.delegate as? NSView)
        ?? fieldEditorOwner(for: fieldEditor, in: window.contentView)
      return NoteLinkPickerFocusOrigin(
        window: window,
        responder: responder,
        fieldEditorOwner: owner,
        fieldEditorSelection: fieldEditor.selectedRange()
      )
    }

    @discardableResult
    func restore() -> Bool {
      guard let window else { return false }
      if let owner = fieldEditorOwner, owner.window === window,
        window.makeFirstResponder(owner),
        let fieldEditor = (owner as? NSControl)?.currentEditor() as? NSTextView,
        window.firstResponder === fieldEditor
      {
        if let fieldEditorSelection { fieldEditor.setSelectedRange(fieldEditorSelection) }
        return true
      }
      if let responder {
        if let view = responder as? NSView, view.window !== window { return false }
        if window.makeFirstResponder(responder), window.firstResponder === responder {
          return true
        }
      }
      return false
    }

    private static func fieldEditorOwner(for fieldEditor: NSTextView, in view: NSView?) -> NSView? {
      guard let view else { return nil }
      if let control = view as? NSControl,
        view.window?.fieldEditor(false, for: control) === fieldEditor
      {
        return control
      }
      for subview in view.subviews {
        if let owner = fieldEditorOwner(for: fieldEditor, in: subview) { return owner }
      }
      return nil
    }
  }

  @MainActor
  final class NoteLinkPickerWindowObserver: NSView {
    let onWindowChange: (NSWindow?) -> Void

    init(onWindowChange: @escaping (NSWindow?) -> Void) {
      self.onWindowChange = onWindowChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChange(window)
    }
  }

  struct NoteLinkPickerWindowReader: NSViewRepresentable {
    let controller: NoteLinkPickerController

    func makeNSView(context: Context) -> NoteLinkPickerWindowObserver {
      NoteLinkPickerWindowObserver { window in
        controller.setHostingWindow(window)
      }
    }

    func updateNSView(_ nsView: NoteLinkPickerWindowObserver, context: Context) {
      controller.setHostingWindow(nsView.window)
    }
  }

  struct NoteLinkPickerView: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.fleckChromeAppearance) private var appearance
    @ObservedObject var controller: NoteLinkPickerController
    let notes: [Note]
    let foldersByID: [UUID: String]
    let accent: Color
    let currentNoteIDs: () -> Set<UUID>
    let currentSource: () -> (UUID, UInt64)?
    let onChoose: (UUID, NSRange) -> Void
    @FocusState private var isQueryFocused: Bool
    @State private var resultsHeight: CGFloat = 220

    static func accessibilityLabel(
      for result: WorkspaceSearchResult,
      folderName: String?,
      snippet: String? = nil
    ) -> String {
      [result.displayTitle, folderName, snippet ?? result.snippet]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    var body: some View {
      let solid = NotesSolidChrome(theme: theme, appearance: appearance)
      let compact = solid.isActive
      ZStack(alignment: .top) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { controller.dismiss() }

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Image(systemName: "link")
              .font(compact ? .system(size: 12) : nil)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            TextField("Link to note", text: $controller.query)
              .font(compact ? .system(size: 14) : nil)
              .textFieldStyle(.plain)
              .focusEffectDisabled()
              .focused($isQueryFocused)
              .fleckNeutralControlOutline(
                isFocused: isQueryFocused,
                cornerRadius: 6,
                idleOpacity: 0.22
              )
              .accessibilityLabel("Link to note")
              .onKeyPress(.upArrow) {
                controller.moveHighlight(.up)
                return .handled
              }
              .onKeyPress(.downArrow) {
                controller.moveHighlight(.down)
                return .handled
              }
              .onKeyPress(.return) {
                let source = currentSource()
                _ = controller.handleKey(
                  .return,
                  currentNoteIDs: currentNoteIDs(),
                  currentSourceNoteID: source?.0,
                  currentSourceRevision: source?.1,
                  activate: onChoose
                )
                return .handled
              }
              .onKeyPress(.escape) {
                controller.dismiss()
                return .handled
              }
            Button {
              controller.dismiss()
            } label: {
              Image(systemName: "xmark")
                .font(compact ? .system(size: 10, weight: .medium) : nil)
                .frame(minWidth: compact ? 16 : nil, minHeight: compact ? 24 : nil)
            }
            .buttonStyle(FleckQuietButtonStyle())
            .accessibilityLabel("Dismiss note link picker")
          }

          Text(
            compact && controller.isUpdatingResults ? "Updating search results"
              : !controller.hasQuery ? "Recent notes"
              : compact && controller.results.isEmpty ? "0 results"
              : controller.resultCountAccessibilityValue
          )
            .font(compact ? .system(size: 11) : .caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note link result count")
            .accessibilityValue(controller.resultCountAccessibilityValue)

          if controller.results.isEmpty {
            Text(
              controller.hasQuery ? "No matching notes" : "No other notes"
            )
            .font(compact ? .system(size: 14) : .callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .opacity(controller.isUpdatingResults ? 0 : 1)
            .accessibilityHidden(controller.isUpdatingResults)
          } else {
            let resultsAreCurrent = controller.resultsAreCurrent
            let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            ScrollViewReader { scrollProxy in
              ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                  ForEach(controller.results) { result in
                    let selected = controller.isHighlighted(result.noteID)
                    let note = notesByID[result.noteID]
                    let folderName = note?.folderID.flatMap { foldersByID[$0] }
                    let snippet = compact && !controller.isShowingRecentNotes
                      ? NotesQueryPanelChrome.snippet(for: result, in: note)
                      : result.snippet
                    Button {
                      let source = currentSource()
                      _ = controller.activateResult(
                        result.noteID,
                        currentNoteIDs: currentNoteIDs(),
                        currentSourceNoteID: source?.0,
                        currentSourceRevision: source?.1,
                        activate: onChoose
                      )
                    } label: {
                      VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayTitle)
                          .font(compact ? .system(size: 14, weight: .medium) : .body.weight(.semibold))
                          .lineLimit(1)
                        if compact {
                          Text([folderName, snippet.isEmpty ? nil : snippet].compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color(.caption))
                            .lineLimit(2)
                        } else {
                          HStack(spacing: 5) {
                            if let folderName {
                              Text(folderName)
                                .font(.caption2)
                                .foregroundStyle(accent)
                            }
                            Text(snippet)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                              .lineLimit(2)
                          }
                        }
                      }
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(.horizontal, 8)
                      .padding(.vertical, compact ? 9 : 6)
                      .frame(minHeight: compact ? 50 : nil, alignment: .leading)
                      .background {
                        if selected {
                          RoundedRectangle(cornerRadius: 6).fill(
                            compact ? NotesQueryPanelChrome.linkSelection : accent.opacity(0.14)
                          )
                        }
                      }
                      .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(resultsAreCurrent)
                    .id(result.noteID)
                    .accessibilityLabel(Self.accessibilityLabel(for: result, folderName: folderName, snippet: snippet))
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(resultsAreCurrent ? "" : "Updating search results")
                    .disabled(!resultsAreCurrent)
                  }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                  if compact && height > 0 { resultsHeight = height }
                }
              }
              .frame(maxHeight: compact && controller.results.count <= 3 ? min(220, resultsHeight) : 220)
              .onChange(of: controller.highlightedNoteID) { _, noteID in
                guard let noteID else { return }
                scrollProxy.scrollTo(noteID, anchor: .center)
              }
            }
          }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .modifier(NotesQueryPanelChrome(solid: solid, cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.horizontal, 20)
      .padding(.top, 48)
      .onMoveCommand { direction in
        switch direction {
        case .up: controller.moveHighlight(.up)
        case .down: controller.moveHighlight(.down)
        default: break
        }
      }
      .onExitCommand { controller.dismiss() }
      .onAppear {
        isQueryFocused = true
        controller.refresh(in: notes)
      }
      .onChange(of: controller.query) {
        controller.refresh(in: notes)
      }
      .onChange(of: notes) { _, newNotes in
        controller.refresh(in: newNotes)
      }
      .onDisappear { controller.dismiss() }
    }
  }
#endif
