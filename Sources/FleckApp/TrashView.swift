#if os(macOS)
  import SwiftUI
  import FleckCore

  struct TrashView: View {
    private enum Focus: Hashable {
      case done
      case restore(UUID)
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.fleckChromeAppearance) private var appearance
    @Environment(\.locale) private var locale
    @FocusState private var focus: Focus?
    let onDone: () -> Void
    var now: () -> Date = { Date() }

    private var solidChrome: NotesSolidChrome {
      NotesSolidChrome(theme: theme, appearance: appearance)
    }

    var body: some View {
      Group {
        if solidChrome.isActive {
          solidTrash
        } else {
          legacyTrash
        }
      }
      .task {
        await appState.refreshTrash()
      }
    }

    private var solidTrash: some View {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Trash")
              .font(.system(size: 20, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Text("Deleted notes are kept on this Mac for 30 days.")
              .font(.system(size: 12))
              .foregroundStyle(theme.color(.caption))
          }
          Spacer(minLength: 12)
          Button(action: onDone) {
            trashButtonLabel("Done", width: 58, prominent: true)
          }
          .focused($focus, equals: .done)
          .fleckNeutralControlOutline(isFocused: focus == .done, cornerRadius: 6)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("notes-trash-done")
        }
        .padding(.horizontal, 19)
        .frame(height: 82)
        .background(solidChrome.dialogHeader)
        .overlay(alignment: .bottom) { trashSeparator }

        if appState.trashedNotes.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "trash")
              .font(.system(size: 25))
              .foregroundStyle(theme.color(.caption))
              .accessibilityHidden(true)
            Text("Trash is Empty")
              .font(.system(size: 17, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Text("Notes you delete will appear here for 30 days.")
              .font(.system(size: 12))
              .foregroundStyle(theme.color(.caption))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(appState.trashedNotes) { trashedNote in
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(trashedNote.note.displayTitle)
                      .font(.system(size: 14, weight: .semibold))
                      .lineLimit(1)
                    Text(deletionDescription(for: trashedNote))
                      .font(.system(size: 11))
                      .foregroundStyle(theme.color(.caption))
                      .lineLimit(1)
                  }
                  Spacer(minLength: 0)
                  Button {
                    restoreInPlace(trashedNote)
                  } label: {
                    trashButtonLabel("Restore", width: 68)
                  }
                  .focused($focus, equals: .restore(trashedNote.id))
                  .fleckNeutralControlOutline(
                    isFocused: focus == .restore(trashedNote.id), cornerRadius: 6
                  )
                  .accessibilityLabel("Restore \(trashedNote.note.displayTitle)")
                  .accessibilityIdentifier("notes-trash-restore-\(trashedNote.id.uuidString)")
                }
                .frame(height: 66)
                .overlay(alignment: .bottom) { trashSeparator }
              }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 6)
            .animation(motion.standard, value: appState.trashedNotes.map(\.id))
          }
        }

        if let error = appState.trashUpdateError {
          Text("Could not update Trash: \(error)")
            .font(.system(size: 12))
            .foregroundStyle(theme.color(.error))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 19)
            .padding(.bottom, 16)
            .accessibilityIdentifier("notes-trash-error")
        }
      }
      .buttonStyle(.plain)
    }

    private func restoreInPlace(_ trashedNote: TrashedNote) {
      let notes = appState.trashedNotes
      guard let index = notes.firstIndex(where: { $0.id == trashedNote.id }) else { return }
      let neighbor = index + 1 < notes.count ? notes[index + 1] : (index > 0 ? notes[index - 1] : nil)
      guard appState.restore(trashedNote, selectsRestoredNote: false) != nil else { return }
      if focus == .restore(trashedNote.id) { focus = neighbor.map { .restore($0.id) } ?? .done }
    }

    private var trashSeparator: some View {
      Rectangle()
        .fill(solidChrome.dialogSeparator)
        .frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func trashButtonLabel(_ title: String, width: CGFloat, prominent: Bool = false) -> some View {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.color(prominent ? .accentText : .textPrimary))
        .frame(width: width, height: 28)
        .background {
          RoundedRectangle(cornerRadius: 6)
            .fill(prominent ? theme.color(.accent) : solidChrome.toolbarField)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(solidChrome.outline, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var legacyTrash: some View {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Trash")
              .font(.title2.weight(.semibold))
            Text("Deleted notes are kept on this Mac for 30 days.")
              .font(.callout)
              .foregroundStyle(theme.color(.textSecondary))
          }
          Spacer()
          Button("Done", action: onDone)
          .keyboardShortcut(.defaultAction)
        }
        .padding()

        Divider()

        if appState.trashedNotes.isEmpty {
          ContentUnavailableView(
            "Trash is Empty",
            systemImage: "trash",
            description: Text("Notes you delete will appear here for 30 days.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(appState.trashedNotes) { trashedNote in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(trashedNote.note.displayTitle)
                  .font(.headline)
                  .lineLimit(1)
                Text(deletionDescription(for: trashedNote))
                  .font(.caption)
                  .foregroundStyle(theme.color(.textSecondary))
              }
              Spacer()
              Button("Restore") {
                appState.restore(trashedNote)
              }
            }
            .padding(.vertical, 4)
            .transition(
              .opacity.combined(
                with: .offset(x: motion.offset)
              )
            )
          }
          .animation(motion.standard, value: appState.trashedNotes.map(\.id))
        }

        if let error = appState.saveError {
          Text("Could not update Trash: \(error)")
            .font(.caption)
            .foregroundStyle(theme.color(.error))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
      }
    }

    private var motion: AppMotion {
      AppMotion(reduceMotion: reduceMotion)
    }

    private func deletionDescription(for trashedNote: TrashedNote) -> String {
      let deletionDate = trashedNote.deletedAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
      )
      let expiry = trashedNote.deletedAt.addingTimeInterval(30 * 24 * 60 * 60)
      let daysRemaining = max(0, Int(ceil(expiry.timeIntervalSince(now()) / (24 * 60 * 60))))
      let dayLabel = daysRemaining == 1 ? "day" : "days"
      return "Deleted \(deletionDate) · \(daysRemaining) \(dayLabel) remaining"
    }
  }
#endif
