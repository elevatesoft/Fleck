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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fleckThemeSnapshot) private var theme
    @StateObject private var model: DictationHistoryViewModel
    @ObservedObject private var history: DictationHistoryController
    @FocusState private var headerFocus: HeaderAction?
    private let notesChrome: NotesSolidChrome?
    let onOpenDestination: (UUID) -> Void

    private enum HeaderAction { case clear, done }

    init(
      history: DictationHistoryController,
      notesChrome: NotesSolidChrome? = nil,
      onOpenDestination: @escaping (UUID) -> Void
    ) {
      _model = StateObject(wrappedValue: DictationHistoryViewModel(controller: history))
      _history = ObservedObject(wrappedValue: history)
      self.notesChrome = notesChrome?.isActive == true ? notesChrome : nil
      self.onOpenDestination = onOpenDestination
    }

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: notesChrome == nil ? nil : 8) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Dictation History")
              .font(notesChrome == nil ? .title2.weight(.semibold) : .system(size: 20, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            if notesChrome != nil {
              Text("Local transcripts · Kept for 30 days")
                .font(.system(size: 12))
                .foregroundStyle(theme.color(.caption))
            }
          }
          .padding(.bottom, notesChrome == nil ? 0 : 6)
          Spacer()
          headerActions
        }
        .padding(.horizontal, notesChrome == nil ? 16 : 22)
        .padding(.vertical, 16)
        .frame(height: notesChrome == nil ? nil : 82)
        .background {
          if let notesChrome { notesChrome.historyHeader }
        }
        .overlay(alignment: .bottom) {
          if let notesChrome {
            Rectangle().fill(notesChrome.historySeparator).frame(height: 1)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }

        if notesChrome == nil { Divider() }

        if history.records.isEmpty {
          if notesChrome != nil {
            VStack(spacing: 0) {
              Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(theme.color(.textSecondary))
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
              Text("No Dictation History")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 17)
              Text("Successful captures kept for recovery appear here for 30 days.")
                .font(.system(size: 14))
                .foregroundStyle(theme.color(.textSecondary))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)
                .padding(.top, 15)
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
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(history.records) { record in
                historyRow(record)
                  .padding(.vertical, 12)
                  .overlay(alignment: .bottom) {
                    Rectangle().fill(notesChrome.historySeparator).frame(height: 1)
                      .allowsHitTesting(false)
                      .accessibilityHidden(true)
                  }
              }
            }
            .padding(.horizontal, 22)
          }
        } else {
          List(history.records) { record in
            historyRow(record)
          }
          .listStyle(.inset)
        }
      }
      .frame(minWidth: notesChrome == nil ? 640 : 680, minHeight: notesChrome == nil ? 440 : 490)
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
      .task {
        await history.load()
      }
      .confirmationDialog(
        confirmationTitle,
        isPresented: Binding(
          get: { model.pendingConfirmation != nil },
          set: { if !$0 { model.cancelConfirmation() } }
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
      let clear = Button("Clear History", role: .destructive) { model.requestClear() }
      let done = Button("Done") { dismiss() }
      if let notesChrome {
        clear
          .buttonStyle(NotesSolidActionStyle(width: 116, height: 32, ink: theme.color(isEmpty ? .caption : .error)))
          .focused($headerFocus, equals: .clear)
          .fleckNeutralControlOutline(isFocused: headerFocus == .clear, cornerRadius: 6)
          .disabled(isEmpty)
        done
          .buttonStyle(NotesSolidActionStyle(
            width: 66, height: 32, ink: theme.color(.accentText), surface: notesChrome.historyDone
          ))
          .focused($headerFocus, equals: .done)
          .fleckNeutralControlOutline(isFocused: headerFocus == .done, cornerRadius: 6)
          .keyboardShortcut(.defaultAction)
      } else {
        clear.disabled(isEmpty)
        done.keyboardShortcut(.defaultAction)
      }
    }

    private func historyRow(_ record: DictationHistoryRecord) -> some View {
      HistoryRow(
        record: record, solid: notesChrome != nil, onOpenDestination: onOpenDestination,
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
    let record: DictationHistoryRecord
    let solid: Bool
    let onOpenDestination: (UUID) -> Void
    let onDelete: () -> Void

    var body: some View {
      let presentation = DictationHistoryRowPresentation(record: record)
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
        .modifier(HistoryRowButtonStyle(solid: solid))
      }
      .padding(.vertical, 8)
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

  private struct HistoryRowButtonStyle: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
      if solid { content.buttonStyle(.bordered) }
      else { content.buttonStyle(.borderless) }
    }
  }
#endif
