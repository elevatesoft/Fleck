#if os(macOS)
  import AppKit
  import FleckCore
  import IOKit.hidsystem
  import SwiftUI

  struct NotesModifierAttemptObserver: NSViewRepresentable {
    let onPress: (DictationModifierKey) -> Void

    func makeNSView(context: Context) -> ModifierEventView { ModifierEventView() }

    func updateNSView(_ view: ModifierEventView, context: Context) {
      view.onPress = onPress
    }

    static func dismantleNSView(_ view: ModifierEventView, coordinator: ()) {
      view.removeMonitor()
    }

    final class ModifierEventView: NSView {
      var onPress: ((DictationModifierKey) -> Void)?
      private var monitor: Any?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
          if let self, let window, window.isKeyWindow,
            (event.window ?? NSApp.keyWindow) === window,
            let modifier = Self.pressedModifier(keyCode: event.keyCode, flags: event.modifierFlags)
          {
            onPress?(modifier)
          }
          return event
        }
      }

      static func pressedModifier(
        keyCode: UInt16, flags: NSEvent.ModifierFlags
      ) -> DictationModifierKey? {
        guard let modifier = ModifierKeyEventTap.modifier(forVirtualKey: UInt32(keyCode))
        else { return nil }
        let mask: UInt = switch modifier {
        case .function: NSEvent.ModifierFlags.function.rawValue
        case .leftCommand: UInt(NX_DEVICELCMDKEYMASK)
        case .rightCommand: UInt(NX_DEVICERCMDKEYMASK)
        case .leftOption: UInt(NX_DEVICELALTKEYMASK)
        case .rightOption: UInt(NX_DEVICERALTKEYMASK)
        case .leftControl: UInt(NX_DEVICELCTLKEYMASK)
        case .rightControl: UInt(NX_DEVICERCTLKEYMASK)
        }
        return flags.rawValue & mask != 0 ? modifier : nil
      }

      func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      isolated deinit { removeMonitor() }
    }
  }

  struct NotesBannerSurface: ViewModifier {
    @Environment(\.fleckThemeSnapshot) private var theme
    var isError = false

    func body(content: Content) -> some View {
      let shape = RoundedRectangle(cornerRadius: 7)
      let fill = ink(isError ? "#2B2223" : "#242628")
      let border = isError
        ? ink("#FF969B").opacity(theme.increasedContrast ? 0.65 : 37.0 / 255)
        : Color.white.opacity(theme.increasedContrast ? 0.3 : 18.0 / 255)
      content
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 34)
        .foregroundStyle(ink(isError ? "#FFA9A5" : "#F2F2F0"))
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
    }

    private func ink(_ hex: String) -> Color {
      Color(nsColor: NSColor(hex: hex)!)
    }
  }

  struct NotesBannerButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
      let shape = RoundedRectangle(cornerRadius: 5)
      configuration.label
        .contentShape(Rectangle())
        .fleckHoverFill(in: shape, opacity: 25.0 / 255)
        .overlay {
          shape.strokeBorder(.white.opacity(isFocused ? 0.75 : outlined ? 0.13 : 0), lineWidth: 1)
            .allowsHitTesting(false)
        }
        .opacity(configuration.isPressed ? 0.82 : 1)
    }
  }

  struct NotesDictationPermissionsBanner: View {
    @Environment(\.font) private var notesFont
    @Environment(\.fleckThemeSnapshot) private var theme

    let openMicrophone: () -> Void
    let openSpeechRecognition: () -> Void
    let dismiss: () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .top, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 12))
              .frame(width: NotesPaperIcon.Glyph.folder.size)
              .foregroundStyle(.white.opacity(theme.increasedContrast ? 1 : 0.7))
              .accessibilityHidden(true)
            Text("Dictation needs permission")
              .font(notesFont ?? .body)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          Button(action: dismiss) {
            Image(systemName: "xmark")
              .font(.system(size: 11, weight: .medium))
              .frame(minWidth: 28, minHeight: 28)
          }
          .buttonStyle(NotesBannerButtonStyle())
          .accessibilityLabel("Dismiss dictation capture failure")
          .help("Dismiss")
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 6) {
            settingsButton("Microphone Settings", open: openMicrophone, fillsRow: false)
            settingsButton("Speech Recognition Settings", open: openSpeechRecognition, fillsRow: false)
          }
          .fixedSize(horizontal: true, vertical: false)
          VStack(spacing: 0) {
            settingsButton("Microphone Settings", open: openMicrophone, fillsRow: true)
            Rectangle()
              .fill(.white.opacity(theme.increasedContrast ? 0.3 : 0.1))
              .frame(height: 1)
              .accessibilityHidden(true)
            settingsButton("Speech Recognition Settings", open: openSpeechRecognition, fillsRow: true)
          }
        }
      }
      .modifier(NotesBannerSurface())
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(2)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notes-dual-dictation-permission")
    }

    private func settingsButton(_ title: String, open: @escaping () -> Void, fillsRow: Bool) -> some View {
      Button(action: open) {
        Text(title)
          .font(notesFont ?? .body)
          .fixedSize(horizontal: !fillsRow, vertical: true)
          .padding(.horizontal, fillsRow ? 8 : 6)
          .padding(.vertical, fillsRow ? 5 : 0)
          .frame(maxWidth: fillsRow ? .infinity : nil, minHeight: 28, alignment: .leading)
      }
      .buttonStyle(NotesBannerButtonStyle(outlined: !fillsRow))
      .help(title)
    }
  }

  struct NotesBannerNotice: View {
    enum Icon {
      case system(String)
      case save
    }

    struct Action: Identifiable {
      let title: String
      var identifier: String? = nil
      var help: String? = nil
      let perform: () -> Void

      var id: String { title }
    }

    @Environment(\.fleckThemeSnapshot) private var theme
    let icon: Icon
    let message: String
    var detail: String? = nil
    var isError = false
    var actions: [Action] = []
    var onDismiss: Action? = nil

    var body: some View {
      HStack(alignment: onDismiss != nil ? .top : .center, spacing: 4) {
        if actions.isEmpty {
          copyWithIcon
        } else if actions.count > 1 {
          stacked
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
              copyWithIcon.frame(minWidth: 266, idealWidth: 270, maxWidth: .infinity)
              button(actions[0])
            }
            stacked
          }
        }
        if let onDismiss {
          Button(action: onDismiss.perform) {
            Image(systemName: "xmark")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(NotesBannerButtonStyle())
          .accessibilityLabel(onDismiss.title)
          .help("Dismiss")
          .padding(.top, detail == nil ? 0 : 3)
        }
      }
      .modifier(NotesBannerSurface(isError: isError))
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(2)
      .accessibilityElement(children: .contain)
    }

    private var copyWithIcon: some View {
      HStack(alignment: .center, spacing: 8) {
        Group {
          switch icon {
          case .system(let symbol):
            Image(systemName: symbol).font(.system(size: 12))
          case .save:
            saveGlyph.stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
              .frame(width: 12, height: 12)
          }
        }
          .foregroundStyle(iconInk)
          .frame(width: 14)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(message).font(.system(size: 12))
          if let detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(theme.increasedContrast ? Color.primary : mutedInk)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.vertical, detail == nil ? 0 : 4)
      }
    }

    private var stacked: some View {
      VStack(alignment: .leading, spacing: 0) {
        copyWithIcon
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) { ForEach(actions) { button($0) } }
            .frame(minWidth: actions.count > 1 ? 400 : 0, alignment: .leading)
          VStack(alignment: .leading, spacing: 0) { ForEach(actions) { button($0) } }
        }
        .padding(.leading, 22)
      }
    }

    private func button(_ action: Action) -> some View {
      Button(action: action.perform) {
        Text(action.title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color(nsColor: NSColor(hex: "#F2F2F0")!))
          .padding(.horizontal, 8)
          .frame(minWidth: 28, minHeight: 28)
          .fixedSize(horizontal: true, vertical: false)
      }
      .buttonStyle(NotesBannerButtonStyle())
      .accessibilityIdentifier(action.identifier ?? action.title)
      .help(action.help ?? action.title)
    }

    private var mutedInk: Color {
      Color(nsColor: NSColor(hex: "#B6B9BD")!)
    }

    private var iconInk: Color {
      if isError { return Color(nsColor: NSColor(hex: "#FF969B")!) }
      return theme.increasedContrast ? .white : mutedInk
    }

    private var saveGlyph: Path {
      Path { path in
        path.addLines([CGPoint(x: 1, y: 11), CGPoint(x: 1, y: 1),
                       CGPoint(x: 8, y: 1), CGPoint(x: 11, y: 4),
                       CGPoint(x: 11, y: 11), CGPoint(x: 1, y: 11)])
        path.addLines([CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 5),
                       CGPoint(x: 8, y: 5), CGPoint(x: 8, y: 2)])
        path.addLines([CGPoint(x: 3, y: 11), CGPoint(x: 3, y: 7),
                       CGPoint(x: 9, y: 7), CGPoint(x: 9, y: 11)])
      }
    }
  }
#endif
