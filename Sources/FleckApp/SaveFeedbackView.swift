#if os(macOS)
  import AppKit
  import Combine
  import Foundation
  import SwiftUI

  enum SaveFeedbackState: Equatable, Sendable {
    case saved
    case pending
    case saving
    case failed

    var accessibilityValue: String {
      switch self {
      case .saved: "All changes saved"
      case .pending: "Changes pending"
      case .saving: "Saving"
      case .failed: "Save failed"
      }
    }

    var helpText: String {
      switch self {
      case .saved: "All changes are saved"
      case .pending: "Changes are waiting to be saved"
      case .saving: "Saving changes"
      case .failed: "Fleck could not save changes. Read the message below the note."
      }
    }
  }

  @MainActor
  final class SaveFeedbackPresentation: ObservableObject {
    typealias RevealScheduler = (Duration, @escaping @MainActor () -> Void) -> Void

    static let revealDelay = Duration.milliseconds(800)
    static let darkSolidNotesRevealDelay = Duration.milliseconds(240)
    static let confirmationIdleDelay = Duration.milliseconds(1500)
    static let confirmationDuration = Duration.seconds(1)

    @Published private(set) var state = SaveFeedbackState.saved
    @Published private(set) var showsSavedConfirmation = false
    private let scheduleReveal: RevealScheduler
    private let scheduleConfirmation: RevealScheduler
    private var activeWrites: Set<UUID> = []
    private var revealedWrites: Set<UUID> = []
    private var confirmationGeneration = UUID()
    private var isIdle = false
    private var needsConfirmation = false

    init(
      scheduleReveal: RevealScheduler? = nil,
      scheduleConfirmation: RevealScheduler? = nil
    ) {
      let scheduler: RevealScheduler = { delay, action in
        Task { @MainActor in
          try? await Task.sleep(for: delay)
          action()
        }
      }
      self.scheduleReveal = scheduleReveal ?? scheduler
      self.scheduleConfirmation = scheduleConfirmation ?? scheduler
    }

    func changesScheduled() {
      confirmationGeneration = UUID()
      let generation = confirmationGeneration
      isIdle = false
      needsConfirmation = true
      if showsSavedConfirmation { showsSavedConfirmation = false }
      if state == .saved { state = .pending }
      scheduleConfirmation(Self.confirmationIdleDelay) { [weak self] in
        guard let self, self.confirmationGeneration == generation else { return }
        self.isIdle = true
        self.showConfirmationIfReady()
      }
    }

    @discardableResult
    func writeBegan(revealAfter delay: Duration? = nil) -> UUID {
      let id = UUID()
      activeWrites.insert(id)
      if showsSavedConfirmation { showsSavedConfirmation = false }
      if revealedWrites.isEmpty { state = .pending }
      scheduleReveal(delay ?? Self.revealDelay) { [weak self] in
        guard let self,
          self.activeWrites.contains(id)
        else { return }
        self.revealedWrites.insert(id)
        self.state = .saving
      }
      return id
    }

    func writeEnded(_ id: UUID) {
      activeWrites.remove(id)
      revealedWrites.remove(id)
      if revealedWrites.isEmpty, state == .saving {
        state = .pending
      }
    }

    func settle(_ outcome: SaveFeedbackState) {
      guard activeWrites.isEmpty, outcome != .saving else { return }
      state = outcome
      if outcome == .saved {
        showConfirmationIfReady()
      } else {
        if showsSavedConfirmation { showsSavedConfirmation = false }
      }
    }

    private func showConfirmationIfReady() {
      guard isIdle, needsConfirmation, state == .saved, activeWrites.isEmpty else { return }
      needsConfirmation = false
      showsSavedConfirmation = true
      let generation = confirmationGeneration
      scheduleConfirmation(Self.confirmationDuration) { [weak self] in
        guard let self, self.confirmationGeneration == generation else { return }
        self.showsSavedConfirmation = false
      }
    }

    func reset() {
      activeWrites.removeAll()
      revealedWrites.removeAll()
      confirmationGeneration = UUID()
      isIdle = false
      needsConfirmation = false
      showsSavedConfirmation = false
      state = .saved
    }
  }

  struct SaveFeedbackView: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    @ObservedObject var presentation: SaveFeedbackPresentation
    let motion: AppMotion
    var usesDarkSolidNotesChrome = false

    var body: some View {
      ZStack(alignment: .trailing) {
        Color.clear
        if usesDarkSolidNotesChrome {
          if presentation.state == .saving {
            paperStatus("Saving", saving: true).transition(.opacity)
          } else if presentation.showsSavedConfirmation {
            paperStatus("Saved", saving: false).transition(.opacity)
          }
        } else if presentation.state == .saving {
          HStack(spacing: 5) {
            ProgressView()
              .controlSize(.mini)
            Text("Saving")
              .foregroundStyle(theme.color(.caption))
          }
          .transition(.opacity)
        } else if presentation.showsSavedConfirmation {
          Label("Saved", systemImage: "checkmark")
            .foregroundStyle(theme.color(.caption))
            .transition(.opacity)
        }
      }
      .fleckUIFont(.caption)
      .frame(width: 62, height: 22, alignment: .trailing)
      .animation(motion.reduceMotion ? nil : motion.quick, value: presentation.state)
      .animation(motion.reduceMotion ? nil : motion.quick, value: presentation.showsSavedConfirmation)
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier("save-feedback")
      .accessibilityLabel("Save status")
      .accessibilityValue(presentation.state.accessibilityValue)
      .help(presentation.state.helpText)
    }

    // Paper V1K-0 / VDG-0: both labels anchor to the same slot coordinates.
    private func paperStatus(_ title: String, saving: Bool) -> some View {
      let ink = Color(nsColor: NSColor(hex: "#BAC0C4")!)
      let glyphInk = Color(nsColor: NSColor(hex: "#AEB3B7")!)
      return HStack(spacing: 6) {
        Group {
          if saving {
            if motion.reduceMotion {
              Image(systemName: "circle.dotted")
                .font(.system(size: 11))
            } else {
              ProgressView().controlSize(.mini)
            }
          } else {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .medium))
          }
        }
        .frame(width: 12, height: 12)
        .foregroundStyle(glyphInk)
        .accessibilityHidden(true)
        Text(title)
          .font(.system(size: 11))
          .lineLimit(1)
          .foregroundStyle(ink)
          .frame(width: 40, height: 16, alignment: .leading)
      }
      .padding(.leading, 4)
      .frame(width: 62, height: 22, alignment: .leading)
    }

  }
#endif
