#if os(macOS)
  import AppKit
  import SwiftUI
  import FleckCore

  struct AgentBannerPresentation: Equatable {
    enum TransitionStyle {
      case crossfade
      case spatial
    }

    private(set) var feedback: AgentChangeFeedback
    private(set) var count: Int

    init(feedback: AgentChangeFeedback, count: Int = 1) {
      self.feedback = feedback
      self.count = count
    }

    var actorName: String {
      switch feedback.actor {
      case .integration(_, let displayName): displayName
      case .localUser: "Fleck"
      }
    }

    var message: String {
      let suffix = count > 1 ? " (\(count))" : ""
      return "\(actorName) updated \(feedback.noteTitle)\(suffix)"
    }

    mutating func coalesce(feedback: AgentChangeFeedback) {
      self.feedback = feedback
      count += 1
    }

    static func transition(reduceMotion: Bool) -> TransitionStyle {
      reduceMotion ? .crossfade : .spatial
    }
  }

  struct AgentChangeBanner: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    let presentation: AgentBannerPresentation
    let motion: AppMotion
    var usesDarkSolidNotesChrome = false
    let onUndo: () -> Void
    let onDoNotShowAgain: () -> Void
    let onDismiss: () -> Void

    var body: some View {
      Group {
        if usesDarkSolidNotesChrome { paperBanner } else { standardBanner }
      }
      .accessibilityElement(children: .contain)
      .transition(
        motion.reduceMotion
          ? .opacity
          : .opacity.combined(with: .offset(y: -motion.offset))
      )
    }

    private var standardBanner: some View {
      HStack(spacing: 8) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
        Text(presentation.message)
          .fleckUIFont(.caption)
          .lineLimit(1)
        Spacer()
        Button("Undo", action: onUndo)
          .buttonStyle(.borderless)
        Button("Do not show again", action: onDoNotShowAgain)
          .fleckUIFont(.caption)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("agent-banner-do-not-show-again")
          .accessibilityLabel("Do not show agent update banners again")
          .accessibilityHint("Turns off routine agent update banners. You can turn them on again in Agents settings.")
        NotesPanelBannerCloseButton(
          label: "Agent Activity update",
          action: onDismiss
        )
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .foregroundStyle(theme.color(.textPrimary))
      .background(theme.color(.raised))
    }

    // W0V-0 / 34GI-0: the action hitboxes never move as their fills appear.
    private var paperBanner: some View {
      let primary = ink("#F2F2F0")
      return HStack(spacing: 0) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 13))
          .foregroundStyle(theme.increasedContrast ? primary : ink("#B6B9BD"))
          .frame(width: 14, height: 14)
          .accessibilityHidden(true)
          .padding(.trailing, 8)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text("\(presentation.actorName) updated \(Text(presentation.feedback.noteTitle).fontWeight(.semibold))")
            .font(.system(size: 12))
            .layoutPriority(0)
          if presentation.count > 1 {
            Text(" · \(presentation.count) updates")
              .font(.system(size: 11))
              .foregroundStyle(ink("#B6B9BD"))
              .layoutPriority(1)
          }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
        HStack(spacing: 4) {
          undoButton
          muteButton
          dismissButton
        }
      }
      .modifier(NotesBannerSurface())
      .padding(.horizontal, 11)
    }

    private var undoButton: some View {
      Button(action: onUndo) {
        Text("Undo")
          .font(.system(size: 12, weight: .medium))
          .frame(width: 48, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(NotesBannerButtonStyle())
    }

    private var muteButton: some View {
      Button(action: onDoNotShowAgain) {
        Text("Do not show again")
          .font(.system(size: 11))
          .foregroundStyle(ink("#C7C9CC"))
          .frame(width: 111, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(NotesBannerButtonStyle())
      .accessibilityIdentifier("agent-banner-do-not-show-again")
      .accessibilityLabel("Do not show agent update banners again")
      .accessibilityHint("Turns off routine agent update banners. You can turn them on again in Agents settings.")
    }

    private var dismissButton: some View {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(NotesBannerButtonStyle())
      .accessibilityLabel("Dismiss Agent Activity update")
      .help("Dismiss")
    }

    private func ink(_ hex: String) -> Color {
      Color(nsColor: NSColor(hex: hex)!)
    }

  }
#endif
