#if os(macOS)
  import AppKit
  import SwiftUI

  struct NotesMenuAction {
    let title: String
    var symbol: String? = nil
    var isEnabled = true
    let perform: () -> Void
  }

  struct NotesAnchoredMenu<Label: View>: View {
    enum Placement {
      case belowTrailing
      case alongside

      func origin(anchor: CGRect, menuWidth: CGFloat, screen: CGRect) -> CGPoint {
        let preferredX: CGFloat
        let y: CGFloat
        switch self {
        case .belowTrailing:
          preferredX = anchor.maxX - menuWidth
          y = anchor.minY - 13
        case .alongside:
          let right = anchor.maxX + 13
          preferredX = right + menuWidth <= screen.maxX ? right : anchor.minX - menuWidth - 13
          y = anchor.maxY + 7
        }
        return CGPoint(x: min(max(preferredX, screen.minX), max(screen.minX, screen.maxX - menuWidth)), y: y)
      }
    }

    let title: String
    let placement: Placement
    let width: CGFloat
    let actions: [NotesMenuAction?]
    let selection: Color
    @ViewBuilder let label: () -> Label
    @State private var isOpen = false
    @StateObject private var presenter = Presenter()

    var body: some View {
      Button {
        guard !isOpen else { return }
        isOpen = true
        let command = presenter.choose(title: title, placement: placement, width: width, actions: actions)
        isOpen = false
        command?()
      } label: {
        label()
          .contentShape(Rectangle())
          .background(isOpen ? selection : .clear, in: RoundedRectangle(cornerRadius: 5))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint("Show menu")
      .background {
        Anchor(presenter: presenter)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }

    private struct Anchor: NSViewRepresentable {
      let presenter: Presenter

      func makeNSView(context: Context) -> NSView { NSView() }
      func updateNSView(_ view: NSView, context: Context) { presenter.anchor = view }
    }

    @MainActor private final class Presenter: ObservableObject {
      weak var anchor: NSView?

      func choose(title: String, placement: Placement, width: CGFloat, actions: [NotesMenuAction?]) -> (() -> Void)? {
        guard let anchor, let window = anchor.window, let screen = window.screen else { return nil }
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.minimumWidth = width
        menu.showsStateColumn = actions.contains { $0?.symbol != nil }
        let target = MenuTarget()
        for (index, action) in actions.enumerated() {
          guard let action else {
            menu.addItem(.separator())
            continue
          }
          let item = NSMenuItem(title: action.title, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
          item.target = target
          item.tag = index
          item.isEnabled = action.isEnabled
          if let symbol = action.symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            #if compiler(>=6.4)
              if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            #endif
          }
          menu.addItem(item)
        }
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let point = placement.origin(anchor: anchorFrame, menuWidth: max(width, menu.size.width), screen: screen.visibleFrame)
        let local = anchor.convert(window.convertPoint(fromScreen: point), from: nil)
        menu.popUp(positioning: nil, at: local, in: anchor)
        return target.selected.flatMap { actions[$0]?.perform }
      }
    }

    @MainActor private final class MenuTarget: NSObject {
      private(set) var selected: Int?

      @objc func choose(_ item: NSMenuItem) {
        selected = item.tag
      }
    }
  }
#endif
