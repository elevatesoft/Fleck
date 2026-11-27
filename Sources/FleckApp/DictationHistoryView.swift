#if os(macOS)
  import AppKit
  import SwiftUI
  import FleckCore

  enum DictationHistoryConfirmation: Equatable {
    case clear
    case delete(UUID)
  }

  @MainActor
  final class DictationHistoryController: ObservableObject {
    typealias LoadOperation = @Sendable () async throws -> [DictationHistoryRecord]
    typealias SaveOperation = @Sendable (DictationHistoryRecord) async throws -> Void
    typealias DeleteOperation = @Sendable (UUID) async throws -> Void
    typealias ClearOperation = @Sendable () async throws -> Void

    @Published private(set) var records: [DictationHistoryRecord]
    @Published var errorMessage: String?
    @Published private(set) var generation = 0

    private let loadOperation: LoadOperation
    private let saveOperation: SaveOperation
    private let deleteOperation: DeleteOperation
    private let clearOperation: ClearOperation
    private var writeTail: Task<Void, Never>?

    init(
      records: [DictationHistoryRecord] = [],
      load: @escaping LoadOperation,
      save: @escaping SaveOperation,
      delete: @escaping DeleteOperation,
      clear: @escaping ClearOperation
    ) {
      self.records = records
      loadOperation = load
      saveOperation = save
      deleteOperation = delete
      clearOperation = clear
    }

    convenience init(store: DictationHistoryStore) {
      self.init(
        load: { try await store.list() },
        save: { try await store.save($0) },
        delete: { try await store.delete(id: $0) },
        clear: { try await store.clear() }
      )
    }

    func load() async {
      await enqueue {
        do {
          self.records = try await self.loadOperation()
          self.errorMessage = nil
        } catch {
          self.errorMessage = "Could not load dictation history: \(error.localizedDescription)"
        }
      }
    }

    @discardableResult
    func save(_ record: DictationHistoryRecord) async -> Bool {
      var saved = false
      await enqueue {
        let previous = self.records
        self.records.removeAll { $0.id == record.id }
        self.records.append(record)
        self.records.sort { $0.completedAt > $1.completedAt }
        do {
          try await self.saveOperation(record)
          self.errorMessage = nil
          saved = true
        } catch {
          self.records = previous
          self.errorMessage = "Could not update dictation history: \(error.localizedDescription)"
        }
      }
      return saved
    }

    @discardableResult
    func delete(_ id: UUID) async -> Bool {
      var deleted = false
      await enqueue {
        let previous = self.records
        self.records.removeAll { $0.id == id }
        do {
          try await self.deleteOperation(id)
          self.errorMessage = nil
          deleted = true
        } catch {
          self.records = previous
          self.errorMessage = "Could not update dictation history: \(error.localizedDescription)"
        }
      }
      return deleted
    }

    func clear() async {
      await enqueue {
        let previous = self.records
        self.records.removeAll()
        do {
          try await self.clearOperation()
          self.errorMessage = nil
        } catch {
          self.records = previous
          self.errorMessage = "Could not update dictation history: \(error.localizedDescription)"
        }
      }
    }

    func waitForPendingWrites() async {
      await writeTail?.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
      let previous = writeTail
      let task = Task { @MainActor in
        await previous?.value
        await operation()
        generation += 1
      }
      writeTail = task
      await task.value
    }
  }

  @MainActor
  final class DictationHistoryViewModel: ObservableObject {
    @Published private(set) var pendingConfirmation: DictationHistoryConfirmation?
    let controller: DictationHistoryController

    init(controller: DictationHistoryController) {
      self.controller = controller
    }

    func requestClear() {
      pendingConfirmation = .clear
    }

    func requestDelete(_ id: UUID) {
      pendingConfirmation = .delete(id)
    }

    func cancelConfirmation() {
      pendingConfirmation = nil
    }

    func confirmRemoval() async {
      guard let removal = pendingConfirmation else { return }
      pendingConfirmation = nil
      switch removal {
      case .clear:
        await controller.clear()
      case .delete(let id):
        await controller.delete(id)
      }
    }
  }

  struct DictationHistoryRowPresentation: Equatable {
    let primaryTitle: String
    let primaryTranscript: String
    let rawTranscript: String?
    let canCopyClean: Bool

    init(record: DictationHistoryRecord) {
      if let cleaned = record.cleanedTranscript, record.cleanupOutcome == .cleaned {
        primaryTitle = "Cleaned"
        primaryTranscript = cleaned
        rawTranscript = record.rawTranscript
        canCopyClean = true
      } else {
        primaryTitle = "Raw fallback"
        primaryTranscript = record.rawTranscript
        rawTranscript = nil
        canCopyClean = false
      }
    }
  }

  struct DictationHistoryView: View {
    private static let paperHeaderHeight: CGFloat = 83

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @StateObject private var model: DictationHistoryViewModel
    @ObservedObject private var history: DictationHistoryController
    @FocusState private var headerFocus: HeaderAction?
    private let notesChrome: NotesSolidChrome?
    private let liveNoteIDs: Set<UUID>?
    let onOpenDestination: (UUID) -> Void

    private enum HeaderAction { case clear, done, cancelClear, confirmClear }

    private var showsPaperClear: Bool {
      notesChrome != nil && model.pendingConfirmation == .clear
    }

    init(
      history: DictationHistoryController,
      notesChrome: NotesSolidChrome? = nil,
      liveNoteIDs: Set<UUID>? = nil,
      onOpenDestination: @escaping (UUID) -> Void
    ) {
      _model = StateObject(wrappedValue: DictationHistoryViewModel(controller: history))
      _history = ObservedObject(wrappedValue: history)
      self.notesChrome = notesChrome?.isActive == true ? notesChrome : nil
      self.liveNoteIDs = liveNoteIDs
      self.onOpenDestination = onOpenDestination
    }

    var body: some View {
      VStack(spacing: 0) {
        if let notesChrome {
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
              Text("Dictation History")
                .font(.system(size: 20, weight: .medium))
                .tracking(0.35)
                .foregroundStyle(paperInk("#ECEEF1"))
                .frame(height: 20)
                .accessibilityAddTraits(.isHeader)
              Text("Local transcripts · Kept for 30 days")
                .font(.system(size: 12))
                .foregroundStyle(paperInk("#B1B6BF"))
                .frame(height: 20)
            }
            .padding(.top, 19)
            Spacer(minLength: 8)
            headerActions
              .padding(.top, 25)
          }
          .padding(.leading, 23)
          .padding(.trailing, 21)
          .frame(height: Self.paperHeaderHeight, alignment: .top)
          .background(notesChrome.historyHeader)
          .overlay(alignment: .bottom) {
            Rectangle().fill(notesChrome.historySeparator).frame(height: 1)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        } else {
          HStack {
            Text("Dictation History")
              .font(.title2.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
            Spacer()
            headerActions
          }
          .padding(16)
          Divider()
        }

        if history.records.isEmpty {
          if notesChrome != nil {
            VStack(spacing: 0) {
              Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(theme.color(.textSecondary))
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
              Text("No Dictation History")
                .font(.system(size: 20, weight: .medium))
                .tracking(0.35)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
              Text("Successful captures kept for recovery appear here for 30 days.")
                .font(.system(size: 14))
                .foregroundStyle(theme.color(.textSecondary))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)
                .padding(.top, 16)
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ContentUnavailableView(
              "No Dictation History",
              systemImage: "waveform",
              description: Text("Successful captures kept for recovery appear here for 30 days.")
            )
          }
        } else if let notesChrome {
          let dateFormatter = paperDateFormatter
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(history.records) { record in
                historyRow(record, paperDateFormatter: dateFormatter)
                  .overlay(alignment: .bottom) {
                    if record.id != history.records.last?.id {
                      Rectangle().fill(notesChrome.historySeparator).frame(height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                  }
              }
            }
            .padding(.horizontal, 23)
          }
        } else {
          List(history.records) { record in
            historyRow(record)
          }
          .listStyle(.inset)
        }
      }
      .frame(minWidth: notesChrome == nil ? 640 : 680, minHeight: notesChrome == nil ? 440 : 490)
      .disabled(showsPaperClear)
      .accessibilityHidden(showsPaperClear)
      .background {
        if let notesChrome { notesChrome.historySurface }
      }
      .overlay {
        if let notesChrome {
          RoundedRectangle(cornerRadius: 14)
            .strokeBorder(notesChrome.historyOutline, lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .overlay {
        if showsPaperClear {
          ZStack {
            Color.black.opacity(0.6).padding(.top, Self.paperHeaderHeight).accessibilityHidden(true)
            paperClearConfirmation.offset(y: 10)
          }
        }
      }
      .onChange(of: showsPaperClear) { _, isPresented in
        headerFocus = isPresented ? .cancelClear : .clear
      }
      .onChange(of: history.records.isEmpty) { _, isEmpty in
        if isEmpty && headerFocus == .clear { headerFocus = .done }
      }
      .task {
        await history.load()
      }
      .confirmationDialog(
        confirmationTitle,
        isPresented: Binding(
          get: { model.pendingConfirmation != nil && !showsPaperClear },
          set: { if !$0 && !showsPaperClear { model.cancelConfirmation() } }
        )
      ) {
        Button(confirmationButtonTitle, role: .destructive) {
          Task { await model.confirmRemoval() }
        }
        Button("Cancel", role: .cancel) {
          model.cancelConfirmation()
        }
      } message: {
        Text(confirmationMessage)
      }
      .alert(
        "Dictation History",
        isPresented: Binding(
          get: { history.errorMessage != nil },
          set: { if !$0 { history.errorMessage = nil } }
        )
      ) {
        Button("OK") {
          history.errorMessage = nil
        }
      } message: {
        Text(history.errorMessage ?? "")
      }
    }

    @ViewBuilder
    private var headerActions: some View {
      let isEmpty = history.records.isEmpty
      if let notesChrome {
        Button(role: .destructive, action: model.requestClear) { paperActionLabel("Clear History") }
          .buttonStyle(NotesSolidActionStyle(
            width: 116, height: 32, ink: paperInk(isEmpty ? "#858B95" : "#FF969B")
          ))
          .focused($headerFocus, equals: .clear)
          .fleckNeutralControlOutline(isFocused: headerFocus == .clear, cornerRadius: 6)
          .disabled(isEmpty)
        Button(action: { dismiss() }) { paperActionLabel("Done") }
          .buttonStyle(NotesSolidActionStyle(
            width: 66, height: 32, ink: theme.color(.accentText), surface: notesChrome.historyDone
          ))
          .focused($headerFocus, equals: .done)
          .fleckNeutralControlOutline(isFocused: headerFocus == .done, cornerRadius: 6)
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Clear History", role: .destructive, action: model.requestClear)
          .disabled(isEmpty)
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }

    private var paperDateFormatter: DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.timeZone = timeZone
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      formatter.doesRelativeDateFormatting = true
      return formatter
    }

    private var paperClearConfirmation: some View {
      let shape = RoundedRectangle(cornerRadius: 12)
      return VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 22) {
          Text(confirmationTitle)
            .font(.system(size: 17, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(paperInk("#ECEEF1"))
            .accessibilityAddTraits(.isHeader)
          Text("This removes all local transcript records.\nThis cannot be undone.")
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(paperInk("#C3C8D0"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 23)

        Rectangle().fill(paperInk("#464A52")).frame(height: 1).accessibilityHidden(true)

        HStack(spacing: 12) {
          Button(role: .cancel, action: model.cancelConfirmation) { paperActionLabel("Cancel") }
            .buttonStyle(NotesSolidActionStyle(
              width: 164, height: 32, ink: paperInk("#ECEEF1"),
              surface: paperInk("#35383E"), outline: paperInk("#464A51")
            ))
            .focused($headerFocus, equals: .cancelClear)
            .fleckNeutralControlOutline(isFocused: headerFocus == .cancelClear, cornerRadius: 6)
            .keyboardShortcut(.cancelAction)
          Button(role: .destructive) {
            Task { await model.confirmRemoval() }
          } label: {
            paperActionLabel("Clear History")
          }
          .buttonStyle(NotesSolidActionStyle(
            width: 164, height: 32, ink: .white,
            surface: paperInk("#B93946"), outline: paperInk("#D15560")
          ))
          .focused($headerFocus, equals: .confirmClear)
          .fleckNeutralControlOutline(isFocused: headerFocus == .confirmClear, cornerRadius: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .frame(height: 70, alignment: .top)
        .background(paperInk("#25282C"))
      }
      .frame(width: 388, height: 196)
      .background(paperInk("#292C31"))
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(paperInk("#53575F"), lineWidth: 1)
          .allowsHitTesting(false)
      }
      .shadow(color: .black.opacity(119.0 / 255), radius: 20, y: 14)
      .accessibilityElement(children: .contain)
    }

    private func paperInk(_ hex: String) -> Color {
      Color(nsColor: NSColor(hex: hex)!)
    }

    private func historyRow(
      _ record: DictationHistoryRecord, paperDateFormatter: DateFormatter? = nil
    ) -> some View {
      HistoryRow(
        record: record, paperDateFormatter: paperDateFormatter, liveNoteIDs: liveNoteIDs,
        onOpenDestination: onOpenDestination,
        onDelete: { model.requestDelete(record.id) }
      )
    }

    private var confirmationTitle: String {
      switch model.pendingConfirmation {
      case .delete:
        "Delete this history item?"
      case .clear:
        "Clear all dictation history?"
      case nil:
        ""
      }
    }

    private var confirmationButtonTitle: String {
      switch model.pendingConfirmation {
      case .delete:
        "Delete"
      case .clear:
        "Clear History"
      case nil:
        ""
      }
    }

    private var confirmationMessage: String {
      switch model.pendingConfirmation {
      case .delete:
        "This removes the local transcript record. This cannot be undone."
      case .clear:
        "This removes all local transcript records. This cannot be undone."
      case nil:
        ""
      }
    }
  }

  private struct HistoryRow: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    let record: DictationHistoryRecord
    let paperDateFormatter: DateFormatter?
    let liveNoteIDs: Set<UUID>?
    let onOpenDestination: (UUID) -> Void
    let onDelete: () -> Void

    var body: some View {
      let presentation = DictationHistoryRowPresentation(record: record)
      if let paperDateFormatter {
        paperRow(presentation, dateFormatter: paperDateFormatter)
      } else {
        standardRow(presentation)
      }
    }

    private func standardRow(_ presentation: DictationHistoryRowPresentation) -> some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(record.completedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.headline)
          Spacer()
          Label(destinationTitle, systemImage: destinationSymbol)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        transcript(presentation.primaryTitle, text: presentation.primaryTranscript)
        if let rawTranscript = presentation.rawTranscript {
          transcript("Raw", text: rawTranscript)
        }

        HStack {
          if presentation.canCopyClean {
            Button("Copy Clean") {
              copy(presentation.primaryTranscript)
            }
          }
          Button("Copy Raw") {
            copy(record.rawTranscript)
          }
          Button("Open Destination") {
            guard let id = record.destination?.noteID else { return }
            onOpenDestination(id)
          }
          .disabled(record.destination == nil || record.insertionOutcome != .saved)
          Spacer()
          Button("Delete", role: .destructive, action: onDelete)
        }
        .buttonStyle(.borderless)
      }
      .padding(.vertical, 8)
    }

    private func paperRow(
      _ presentation: DictationHistoryRowPresentation, dateFormatter: DateFormatter
    ) -> some View {
      let metadata = paperInk("#B9BEC6")
      let showsRawComparison = presentation.rawTranscript != nil
      return VStack(alignment: .leading, spacing: 0) {
        Text(dateFormatter.string(from: record.completedAt))
          .font(.system(size: 12))
          .foregroundStyle(metadata)
          .padding(.bottom, 9)
        paperTranscript(presentation.primaryTitle, text: presentation.primaryTranscript)
        if let rawTranscript = presentation.rawTranscript {
          paperTranscript("Raw", text: rawTranscript, isSecondary: true).padding(.top, 16)
        }
        HStack(spacing: 6) {
          Image(systemName: savedDestination == nil ? "exclamationmark.triangle" : "note.text")
            .font(.system(size: 10))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
          if let savedDestination {
            HStack(spacing: 0) {
              Text("Saved to ")
              if canOpenPaperDestination {
                Button {
                  onOpenDestination(savedDestination.noteID)
                } label: {
                  Text(savedDestination.title).underline()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open the destination note")
              } else {
                Text(savedDestination.title)
              }
            }
          } else {
            Text("Not saved to a note")
          }
        }
        .font(.system(size: 13))
        .foregroundStyle(metadata)
        .padding(.top, showsRawComparison ? 14 : 10)
        HStack(spacing: 8) {
          if presentation.canCopyClean {
            Button(action: { copy(presentation.primaryTranscript) }) {
              paperActionLabel("Copy Clean")
            }
            .buttonStyle(paperAction(width: 90))
          }
          Button(action: { copy(record.rawTranscript) }) {
            paperActionLabel("Copy Raw")
          }
          .buttonStyle(paperAction(width: presentation.canCopyClean ? 82 : 90))
          Button {
            guard canOpenPaperDestination, let savedDestination else { return }
            onOpenDestination(savedDestination.noteID)
          } label: {
            paperActionLabel("Open Destination")
          }
          .buttonStyle(paperAction(width: 140, disabled: !canOpenPaperDestination))
          .disabled(!canOpenPaperDestination)
          Spacer(minLength: 0)
          Button(role: .destructive, action: onDelete) { paperActionLabel("Delete") }
            .buttonStyle(paperAction(width: 70, destructive: true))
        }
        .padding(.top, showsRawComparison ? 11 : 15)
      }
      .padding(.top, 22)
      .padding(.bottom, showsRawComparison ? 19 : 12)
    }

    private func paperTranscript(_ title: String, text: String, isSecondary: Bool = false) -> some View {
      VStack(alignment: .leading, spacing: isSecondary ? 5 : 4) {
        Text(title)
          .font(.system(size: 12))
          .foregroundStyle(paperInk("#B9BEC6"))
        Text(text)
          .font(.system(
            size: isSecondary ? 14 : 16, weight: theme.increasedContrast ? .regular : .light
          ))
          .tracking(0.3)
          .foregroundStyle(paperInk(isSecondary ? "#CDD1D7" : "#ECEEF1"))
          .lineSpacing(4)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    private var savedDestination: DictationDestination? {
      record.insertionOutcome == .saved ? record.destination : nil
    }

    private var canOpenPaperDestination: Bool {
      guard let savedDestination else { return false }
      return liveNoteIDs?.contains(savedDestination.noteID) ?? true
    }

    private func paperInk(_ hex: String) -> Color {
      Color(nsColor: NSColor(hex: hex)!)
    }

    private func paperAction(
      width: CGFloat, disabled: Bool = false, destructive: Bool = false
    ) -> NotesSolidActionStyle {
      let red = paperInk("#FF969B")
      return NotesSolidActionStyle(
        width: width, height: 32,
        ink: destructive ? red : paperInk(disabled ? "#858B95" : "#ECEEF1"),
        surface: destructive ? red.opacity(13.0 / 255) : paperInk(disabled ? "#292C31" : "#35383E"),
        outline: destructive ? red.opacity(40.0 / 255) : paperInk(disabled ? "#34373D" : "#464A51")
      )
    }

    private var destinationTitle: String {
      guard record.insertionOutcome == .saved else { return "Unsaved" }
      return record.destination?.title ?? "Unsaved"
    }

    private var destinationSymbol: String {
      record.insertionOutcome == .saved ? "note.text" : "exclamationmark.triangle"
    }

    @ViewBuilder
    private func transcript(_ title: String, text: String) -> some View {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    private func copy(_ text: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

  private func paperActionLabel(_ title: LocalizedStringKey) -> some View {
    Text(title).font(.system(size: 13))
  }

#endif
