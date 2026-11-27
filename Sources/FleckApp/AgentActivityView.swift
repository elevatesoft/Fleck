#if os(macOS)
  import AppKit
  import SwiftUI
  import FleckCore

  enum AgentPresentation {
    static func visibleNoteIDs(
      in workspace: Workspace,
      activeProfiles: [AgentProfileCapabilities] = []
    ) -> Set<UUID> {
      Set(
        activeProfiles.flatMap {
          AgentCapabilityPolicy.authorizationSnapshot(
            for: $0,
            workspace: workspace
          ).readableNoteIDs
        }
      )
    }

  }

  struct AgentSharingPresentation {
    static let sharedBadgeAccessibilityLabel = "Shared with agents"

    static func isShared(
      noteID: UUID,
      activeProfiles: [AgentProfileCapabilities],
      workspace: Workspace
    ) -> Bool {
      AgentCapabilityPresentation.isShared(
        noteID: noteID,
        activeProfiles: activeProfiles,
        workspace: workspace
      )
    }
  }

  enum AgentActivityClearPresentation {
    static let requiresConfirmation = true
  }

  final class AgentActivityScroller: NSScroller {
    static let visualKnobWidth: CGFloat = 4
    static let visualMinimumKnobLength: CGFloat = 24
    static let visualTrailingInset: CGFloat = 3
    static let visualTrackInset: CGFloat = 3

    private var heldVisualKnobLength: CGFloat?
    private var heldVisualKnobOrigin: (initial: CGFloat, proportional: CGFloat)?
    var knobColor = NSColor.secondaryLabelColor {
      didSet { needsDisplay = true }
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    var visualKnobRect: NSRect {
      visualKnobGeometry.rect
    }

    private var visualKnobGeometry: (rect: NSRect, proportionalY: CGFloat) {
      let width = min(Self.visualKnobWidth, bounds.width)
      let trackInset = min(Self.visualTrackInset, bounds.height / 2)
      let track = bounds.insetBy(dx: 0, dy: trackInset)
      guard width > 0, track.height > 0 else { return (.zero, 0) }

      let proportion = min(max(knobProportion, 0), 1)
      let naturalLength = track.height * proportion
      let length = min(
        track.height,
        heldVisualKnobLength ?? floor(max(Self.visualMinimumKnobLength, naturalLength))
      )
      let position = min(max(CGFloat(doubleValue), 0), 1)
      let travel = track.height - length
      let proportionalY = isFlipped
        ? track.minY + travel * position
        : track.maxY - length - travel * position
      let trailingInset = min(Self.visualTrailingInset, bounds.width - width)
      let x = bounds.maxX - trailingInset - width
      var y = proportionalY

      if let heldOrigin = heldVisualKnobOrigin {
        let translatedY = proportionalY == heldOrigin.proportional
          ? heldOrigin.initial
          : heldOrigin.initial + (proportionalY - heldOrigin.proportional)
        let maximumY = track.maxY - length
        if translatedY.isFinite, track.minY.isFinite, maximumY.isFinite {
          y = min(max(translatedY, track.minY), maximumY)
        }
      } else if heldVisualKnobLength == nil {
        let native = rect(for: .knob)
        let minimumY = max(native.minY, track.minY)
        let maximumY = min(native.maxY - length, track.maxY - length)
        let finiteGeometry = [
          bounds.minX, bounds.minY, bounds.maxX, bounds.maxY, bounds.width, bounds.height,
          track.minY, track.maxY, width, length, knobProportion, CGFloat(doubleValue),
          x, x + width, proportionalY, native.minX, native.minY, native.maxX, native.maxY,
          native.width, native.height, minimumY, maximumY,
        ].allSatisfy { $0.isFinite }
        if finiteGeometry, bounds.width > 0, bounds.height > 0,
          native.width > 0, native.height >= length,
          native.minX <= x, x + width <= native.maxX, minimumY <= maximumY
        {
          let projectedY = min(max(proportionalY, minimumY), maximumY)
          if projectedY != proportionalY {
            y = projectedY
          }
        }
      }

      return (
        NSRect(x: x, y: y, width: width, height: length),
        proportionalY
      )
    }

    override func drawKnob() {
      let rect = visualKnobRect
      guard !rect.isEmpty else { return }
      knobColor.withAlphaComponent(0.7).setFill()
      NSBezierPath(
        roundedRect: rect,
        xRadius: Self.visualKnobWidth / 2,
        yRadius: Self.visualKnobWidth / 2
      ).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func mouseDown(with event: NSEvent) {
      guard testPart(event.locationInWindow) == .knob else {
        super.mouseDown(with: event)
        return
      }

      withHeldVisualKnobGeometry {
        super.mouseDown(with: event)
      }
    }

    func withHeldVisualKnobGeometry(_ body: () -> Void) {
      let initial = visualKnobGeometry
      heldVisualKnobLength = initial.rect.height
      heldVisualKnobOrigin = nil
      if initial.rect.minY.isFinite, initial.proportionalY.isFinite,
        initial.rect.minY != initial.proportionalY
      {
        heldVisualKnobOrigin = (initial.rect.minY, initial.proportionalY)
      }
      defer {
        heldVisualKnobLength = nil
        heldVisualKnobOrigin = nil
        needsDisplay = true
      }
      body()
    }
  }

  struct AgentActivityScrollViewConfigurator: NSViewRepresentable {
    @Environment(\.fleckThemeSnapshot) private var theme

    func makeNSView(context: Context) -> AgentActivityScrollViewConfigurationView {
      let view = AgentActivityScrollViewConfigurationView()
      view.updateKnobColor(theme.nsColor(.textSecondary))
      return view
    }

    func updateNSView(_ view: AgentActivityScrollViewConfigurationView, context: Context) {
      view.updateKnobColor(theme.nsColor(.textSecondary))
    }
  }

  final class AgentActivityScrollViewConfigurationView: NSView {
    private var knobColor = NSColor.secondaryLabelColor

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      configureScrollView()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configureScrollView()
    }

    override func layout() {
      super.layout()
      configureScrollView()
    }

    func configureScrollView() {
      guard let scrollView = enclosingScrollView else { return }
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      var scrollerInsets = scrollView.scrollerInsets
      scrollerInsets.right = 2
      scrollView.scrollerInsets = scrollerInsets
      if let scroller = scrollView.verticalScroller as? AgentActivityScroller {
        scroller.knobColor = knobColor
      } else {
        let scroller = AgentActivityScroller()
        scroller.knobColor = knobColor
        scrollView.verticalScroller = scroller
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    }

    func updateKnobColor(_ color: NSColor) {
      knobColor = color
      configureScrollView()
    }
  }

  struct AgentActivityDiffLine: Equatable {
    enum Kind: Equatable {
      case unchanged
      case removed
      case added
    }

    let kind: Kind
    let text: String

    var marker: String {
      switch kind {
      case .unchanged: " "
      case .removed: "-"
      case .added: "+"
      }
    }

    var accessibilityLabel: String {
      let description =
        switch kind {
        case .unchanged: "Unchanged"
        case .removed: "Removed"
        case .added: "Added"
        }
      return text.isEmpty ? "\(description) empty line" : "\(description): \(text)"
    }
  }

  enum AgentActivityLineDiff {
    private static let maximumLineCount = 400
    private static let maximumUTF8ByteCount = 1024 * 1024

    static func lines(before: String, after: String) -> [AgentActivityDiffLine]? {
      guard before.utf8.count + after.utf8.count <= maximumUTF8ByteCount else {
        return nil
      }
      let beforeLines = splitLines(before)
      let afterLines = splitLines(after)
      guard beforeLines.count + afterLines.count <= maximumLineCount else {
        return nil
      }

      var removals = Set<Int>()
      var insertions = Set<Int>()
      for change in afterLines.difference(from: beforeLines) {
        switch change {
        case .remove(let offset, _, _): removals.insert(offset)
        case .insert(let offset, _, _): insertions.insert(offset)
        }
      }

      var lines: [AgentActivityDiffLine] = []
      var beforeIndex = 0
      var afterIndex = 0
      while beforeIndex < beforeLines.count || afterIndex < afterLines.count {
        if beforeIndex < beforeLines.count, removals.contains(beforeIndex) {
          lines.append(.init(kind: .removed, text: beforeLines[beforeIndex]))
          beforeIndex += 1
        } else if afterIndex < afterLines.count, insertions.contains(afterIndex) {
          lines.append(.init(kind: .added, text: afterLines[afterIndex]))
          afterIndex += 1
        } else if beforeIndex < beforeLines.count, afterIndex < afterLines.count {
          lines.append(.init(kind: .unchanged, text: beforeLines[beforeIndex]))
          beforeIndex += 1
          afterIndex += 1
        } else if beforeIndex < beforeLines.count {
          lines.append(.init(kind: .removed, text: beforeLines[beforeIndex]))
          beforeIndex += 1
        } else {
          lines.append(.init(kind: .added, text: afterLines[afterIndex]))
          afterIndex += 1
        }
      }
      return lines
    }

    private static func splitLines(_ text: String) -> [String] {
      guard !text.isEmpty else { return [] }
      let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      return normalized.components(separatedBy: "\n")
    }
  }

  struct AgentActivityRowPresentation: Identifiable {
    let record: AgentActivityRecord
    let integrationName: String
    let noteTitle: String
    let operationDescription: String
    let timestamp: Date
    let beforeText: String
    let afterText: String
    let diffLines: [AgentActivityDiffLine]?
    let canUndo: Bool

    var id: UUID { record.changeID }

    init(
      record: AgentActivityRecord,
      activeNote: Note?,
      activeProfileIDs: Set<UUID>
    ) {
      self.record = record
      integrationName = Self.actorName(record.actor)
      noteTitle = record.noteTitle
      operationDescription = Self.operationName(record.operation)
      timestamp = record.createdAt
      beforeText = record.patch.beforeText
      afterText = record.patch.afterText
      diffLines = AgentActivityLineDiff.lines(
        before: record.patch.beforeText,
        after: record.patch.afterText
      )
      canUndo =
        activeNote.map { (try? AgentUndoEngine.draft(inverting: record.patch, in: $0.body)) != nil }
        ?? false
    }

    var copiedDetails: String {
      """
      \(integrationName) \(operationDescription.lowercased()) in \(noteTitle)
      \(timestamp.formatted(date: .abbreviated, time: .standard))
      Before: \(beforeText)
      After: \(afterText)
      """
    }

    static func actorName(_ actor: AgentActivityActor) -> String {
      switch actor {
      case .integration(_, let displayName): displayName
      case .localUser: "Fleck"
      }
    }

    static func operationName(_ operation: AgentActivityOperation) -> String {
      switch operation {
      case .appendText: "Appended text"
      case .insertText: "Inserted text"
      case .replaceLines: "Replaced lines"
      case .addTask: "Added task"
      case .renameTask: "Renamed task"
      case .setTaskState: "Updated task"
      case .removeTask: "Removed task"
      case .undoChange: "Undid change"
      }
    }
  }

  struct AgentActivityNoteFilter {
    let notes: [Note]
    let selectedNoteID: UUID?

    var selectedNote: Note? {
      guard let selectedNoteID else { return nil }
      return notes.first { $0.id == selectedNoteID }
    }

    func records(from activity: [AgentActivityRecord]) -> [AgentActivityRecord] {
      guard let selectedNote else { return activity }
      return activity.filter { $0.noteID == selectedNote.id }
    }
  }

  struct AgentActivityView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.fleckThemeSnapshot) private var theme
    var notesChrome: NotesSolidChrome?
    let onOpenNote: (UUID) -> Void
    let onDismiss: () -> Void
    @State private var showsClearConfirmation = false
    @State private var selectedNoteID: UUID?
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
      case clear, done, cancelClear, confirmClear
    }

    private let clearTitle: LocalizedStringKey = "Clear Agent Activity?"
    private let clearMessage: LocalizedStringKey =
      "Visible patches are removed. Retry-protection tombstones remain until expiry."

    private var showsSolidClear: Bool {
      notesChrome != nil && showsClearConfirmation
    }

    private var noteFilter: AgentActivityNoteFilter {
      AgentActivityNoteFilter(
        notes: appState.workspace.notes, selectedNoteID: notesChrome == nil ? nil : selectedNoteID
      )
    }

    var body: some View {
      let records = noteFilter.records(from: appState.agentActivity)
      let isFiltered = noteFilter.selectedNote != nil
      VStack(alignment: .leading, spacing: notesChrome == nil ? 12 : 0) {
        if let notesChrome {
          solidHeader(notesChrome, shownCount: records.count, isFiltered: isFiltered)
          notePicker(notesChrome)
        } else {
          HStack {
            Text("Agent Activity").font(.title2.weight(.semibold))
            Spacer()
            Button("Clear Activity", role: .destructive) {
              showsClearConfirmation = true
            }
            .disabled(appState.agentActivity.isEmpty)
            Button("Done", action: onDismiss)
              .keyboardShortcut(.cancelAction)
              .accessibilityLabel("Close Agent Activity")
          }
          .padding(.horizontal, 18)
        }

        if records.isEmpty {
          emptyActivity(isFiltered: isFiltered)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(records, id: \.changeID) { record in
                AgentActivityEntryView(
                  notesChrome: notesChrome, record: record, onOpenNote: onOpenNote
                )
              }
            }
            .padding(.horizontal, 18)
            .padding(.top, notesChrome == nil ? 0 : 12)
            .background(AgentActivityScrollViewConfigurator())
          }
          .padding(.bottom, 18)
        }
      }
      .padding(.top, notesChrome == nil ? 18 : 0)
      .disabled(showsSolidClear)
      .allowsHitTesting(!showsSolidClear)
      .accessibilityHidden(showsSolidClear)
      .background {
        if let notesChrome { notesChrome.dialogSurface }
      }
      .overlay {
        if let notesChrome, showsSolidClear {
          solidClearConfirmation(notesChrome)
        }
      }
      .onChange(of: showsSolidClear) { _, isPresented in
        focusedControl = isPresented ? .cancelClear : appState.agentActivity.isEmpty ? .done : .clear
      }
      .onChange(of: noteFilter.selectedNote?.id) { _, noteID in
        if noteID == nil { selectedNoteID = nil }
      }
      .task { appState.refreshAgentActivity() }
      .confirmationDialog(
        clearTitle,
        isPresented: Binding(
          get: { notesChrome == nil && showsClearConfirmation },
          set: { if notesChrome == nil { showsClearConfirmation = $0 } }
        )
      ) {
        Button("Clear Activity", role: .destructive, action: clearActivity)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(clearMessage)
      }
    }

    private func solidHeader(
      _ chrome: NotesSolidChrome, shownCount: Int, isFiltered: Bool
    ) -> some View {
      let count = appState.agentActivity.count
      return HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Agent Activity")
            .fleckUIFont(.title2, weight: .semibold)
            .foregroundStyle(theme.color(.textPrimary))
            .accessibilityAddTraits(.isHeader)
          Text(isFiltered
            ? "\(shownCount) of \(count) changes"
            : (count == 1 ? "1 change" : "\(count) changes"))
            .fleckUIFont(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.color(.textSecondary))
        }
        Spacer(minLength: 8)
        solidButton("Clear Activity", control: .clear, role: .destructive, chrome: chrome) {
          showsClearConfirmation = true
        }
        .disabled(count == 0)
        solidButton("Done", control: .done, chrome: chrome, action: onDismiss)
          .keyboardShortcut(showsSolidClear ? nil : .cancelAction)
          .accessibilityLabel("Close Agent Activity")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .background(chrome.dialogHeader)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(chrome.dialogSeparator)
          .frame(height: 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }

    private func notePicker(_ chrome: NotesSolidChrome) -> some View {
      Picker("Note", selection: $selectedNoteID) {
        Text("All Notes").tag(UUID?.none)
        ForEach(noteFilter.notes) { note in
          let folder = appState.workspace.folders.first { $0.id == note.folderID }?.name
          Text(folder.map { "\(note.displayTitle) — \($0)" } ?? note.displayTitle)
            .tag(Optional(note.id))
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("notes-agent-activity-note-filter")
      .padding(.horizontal, 18)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(chrome.dialogHeader)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(chrome.dialogSeparator)
          .frame(height: 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }

    private func emptyActivity(isFiltered: Bool) -> some View {
      let placeholder = ContentUnavailableView(
        isFiltered ? "No Matching Activity" : "No Agent Activity",
        systemImage: "point.3.connected.trianglepath.dotted",
        description: Text(isFiltered
          ? "No changes were recorded for this note."
          : "Changes made by authorized integrations appear here.")
      )
      return Group {
        if notesChrome == nil {
          placeholder
        } else {
          placeholder.foregroundStyle(theme.color(.textSecondary))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 18)
      .padding(.bottom, 18)
    }

    private func solidClearConfirmation(_ chrome: NotesSolidChrome) -> some View {
      let shape = RoundedRectangle(cornerRadius: 12)
      return ZStack {
        Color.black.opacity(0.55)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 12) {
          Text(clearTitle)
            .fleckUIFont(.headline)
            .foregroundStyle(theme.color(.textPrimary))
            .accessibilityAddTraits(.isHeader)
          Text(
            "This clears patches for all notes, regardless of the filter. Retry-protection tombstones remain until expiry."
          )
          .fleckUIFont(.callout)
          .foregroundStyle(theme.color(.textSecondary))
          .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            solidButton("Cancel", control: .cancelClear, role: .cancel, chrome: chrome) {
              showsClearConfirmation = false
            }
            .keyboardShortcut(.cancelAction)
            solidButton(
              "Clear Activity", control: .confirmClear, role: .destructive,
              chrome: chrome, action: clearActivity
            )
          }
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(chrome.dialogHeader, in: shape)
        .overlay {
          shape.strokeBorder(chrome.outline, lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .shadow(radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-agent-activity-clear-confirmation")
        .padding(12)
      }
    }

    private func solidButton(
      _ title: LocalizedStringKey,
      control: Control,
      role: ButtonRole? = nil,
      chrome: NotesSolidChrome,
      action: @escaping () -> Void
    ) -> some View {
      let isDestructive = role == .destructive
      let isDone = control == .done
      let isDisabled = control == .clear && appState.agentActivity.isEmpty
      return Button(title, role: role, action: action)
        .buttonStyle(NotesSolidActionStyle(
          width: isDestructive ? 90 : 58,
          height: 30,
          ink: theme.color(
            isDisabled ? .caption : isDone ? .accentText : isDestructive ? .error : .textPrimary
          ),
          surface: isDone ? theme.color(.accent) : chrome.toolbarField,
          outline: isDone ? .clear : chrome.outline
        ))
        .focused($focusedControl, equals: control)
        .fleckNeutralControlOutline(isFocused: focusedControl == control, cornerRadius: 6)
    }

    private func clearActivity() {
      appState.clearAgentActivity()
      showsClearConfirmation = false
    }
  }

  struct AgentActivityInboxView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.fleckThemeSnapshot) private var theme
    let chrome: NotesSolidChrome
    let onOpenHistory: () -> Void
    let onOpenNote: (UUID) -> Void
    @State private var selectedChangeID: UUID?
    @State private var readIDs: Set<UUID> = []

    private var inboxRecords: [AgentActivityRecord] {
      let noteIDs = Set(appState.workspace.notes.map(\.id))
      return Array(appState.agentActivity.lazy.filter { noteIDs.contains($0.noteID) }.prefix(50))
    }

    var body: some View {
      let records = inboxRecords
      let selectedRecord = records.first { $0.changeID == selectedChangeID }
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          if selectedRecord != nil {
            Button("Back") { selectedChangeID = nil }
          }
          Text("Activity Inbox")
            .fleckUIFont(.title2, weight: .semibold)
            .foregroundStyle(theme.color(.textPrimary))
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 0)
        }
        .padding(12)
        .background(chrome.dialogHeader)

        separator
        if let selectedRecord {
          ScrollView {
            AgentActivityEntryView(
              notesChrome: chrome, record: selectedRecord, onOpenNote: onOpenNote
            )
            .padding(10)
          }
          .frame(height: 230)
          .accessibilityIdentifier("notes-activity-inbox-detail")
          .task(id: selectedRecord.changeID) {
            guard !Task.isCancelled,
              appState.agentActivityStore.markInboxRecordRead(id: selectedRecord.changeID)
            else { return }
            readIDs = appState.agentActivityStore.inboxReadIDs()
          }
        } else if records.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("No Recent Activity").fleckUIFont(.headline)
            Text("Changes made by authorized integrations appear here.")
              .fleckUIFont(.callout)
              .foregroundStyle(theme.color(.textSecondary))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(records, id: \.changeID) { record in
                inboxRow(record)
              }
            }
            .padding(8)
          }
          .frame(height: 200)
        }
        separator

        Button("Open Agent Activity", action: onOpenHistory)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 350)
      .background(chrome.dialogSurface)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notes-activity-inbox")
      .task {
        appState.refreshAgentActivity()
        readIDs = appState.agentActivityStore.inboxReadIDs()
      }
      .onChange(of: selectedRecord?.changeID) { _, changeID in
        if changeID == nil { selectedChangeID = nil }
      }
    }

    private var separator: some View {
      Rectangle()
        .fill(chrome.dialogSeparator)
        .frame(height: 1)
        .accessibilityHidden(true)
    }

    private func inboxRow(_ record: AgentActivityRecord) -> some View {
      let isRead = readIDs.contains(record.changeID)
      let actor = AgentActivityRowPresentation.actorName(record.actor)
      let operation = AgentActivityRowPresentation.operationName(record.operation)
      return Button {
        selectedChangeID = record.changeID
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(isRead ? .clear : theme.color(.accent))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(record.noteTitle)
              .fleckUIFont(.headline)
              .foregroundStyle(theme.color(.textPrimary))
              .lineLimit(1)
            Text("\(actor) · \(operation)")
              .fleckUIFont(.caption)
              .foregroundStyle(theme.color(.textSecondary))
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          Text(record.createdAt, style: .relative)
            .fleckUIFont(.caption)
            .foregroundStyle(theme.color(.caption))
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(theme.color(.caption))
            .accessibilityHidden(true)
        }
        .padding(8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fleckHoverFill(in: RoundedRectangle(cornerRadius: 6))
      .accessibilityIdentifier("notes-activity-inbox-row-\(record.changeID.uuidString)")
      .accessibilityValue(isRead ? "Read" : "Unread")
    }
  }

  struct AgentActivityEntryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.fleckThemeSnapshot) private var theme
    let notesChrome: NotesSolidChrome?
    let record: AgentActivityRecord
    let onOpenNote: (UUID) -> Void

    var body: some View {
      activityRow(AgentActivityRowPresentation(
        record: record,
        activeNote: appState.workspace.notes.first { $0.id == record.noteID },
        activeProfileIDs: Set(appState.agentProfiles.map(\.id))
      ))
    }

    private func activityRow(_ row: AgentActivityRowPresentation) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(row.integrationName).font(.headline)
          Text("· \(row.noteTitle)").foregroundStyle(theme.color(.textSecondary))
          Spacer()
          Text(row.timestamp, style: .relative)
            .font(.caption)
            .foregroundStyle(theme.color(.caption))
        }
        Text(row.operationDescription).font(.callout)
        if let lines = row.diffLines {
          diff(lines)
        } else {
          patch("Before", row.beforeText)
          patch("After", row.afterText)
          Text("This change is too large to display as a line diff.")
            .font(.caption2)
            .foregroundStyle(theme.color(.caption))
        }
        HStack {
          Button("Open Note") {
            onOpenNote(row.record.noteID)
          }
          Button("Copy Details") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.copiedDetails, forType: .string)
          }
          Spacer()
          Button("Undo") {
            Task { await appState.undoAgentChange(row.record) }
          }
          .disabled(!row.canUndo)
        }
      }
      .padding(12)
      .background {
        let shape = RoundedRectangle(cornerRadius: 10)
        if let notesChrome {
          shape.fill(notesChrome.dialogHeader)
          shape.strokeBorder(notesChrome.dialogSeparator, lineWidth: 1)
        } else {
          shape.fill(.quaternary.opacity(0.35))
        }
      }
    }

    private func diff(_ lines: [AgentActivityDiffLine]) -> some View {
      VStack(alignment: .leading, spacing: 3) {
        Text("Changes")
          .font(.caption.weight(.medium))
          .foregroundStyle(theme.color(.caption))
        if lines.isEmpty {
          Text("—")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(theme.color(.caption))
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
              diffLine(lines[index])
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .textSelection(.enabled)
        }
      }
    }

    private func diffLine(_ line: AgentActivityDiffLine) -> some View {
      HStack(alignment: .top, spacing: 6) {
        Text(line.marker)
          .font(.system(.caption, design: .monospaced).weight(.semibold))
          .frame(width: 10, alignment: .center)
        Text(line.text.isEmpty ? " " : line.text)
          .font(.system(.caption, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .foregroundStyle(diffColor(line.kind))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(diffBackground(line.kind))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(line.accessibilityLabel)
    }

    private func diffColor(_ kind: AgentActivityDiffLine.Kind) -> Color {
      switch kind {
      case .unchanged: theme.color(.textSecondary)
      case .removed: theme.color(.error)
      case .added: theme.color(.success)
      }
    }

    private func diffBackground(_ kind: AgentActivityDiffLine.Kind) -> Color {
      let opacity = theme.increasedContrast ? 0.20 : 0.10
      return switch kind {
      case .unchanged: .clear
      case .removed: theme.color(.error).opacity(opacity)
      case .added: theme.color(.success).opacity(opacity)
      }
    }

    private func patch(_ label: String, _ text: String) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption.weight(.medium))
          .foregroundStyle(theme.color(.caption))
        Text(text.isEmpty ? "—" : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }
#endif
