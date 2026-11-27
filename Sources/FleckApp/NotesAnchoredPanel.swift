#if os(macOS)
  import AppKit
  import SwiftUI

  struct NotesAnchoredPanel<Item: Equatable, Content: View>: NSViewRepresentable {
    @Environment(\.fleckUIFont) private var uiFont
    @Environment(\.font) private var font
    @Binding var item: Item?
    let chrome: NotesSolidChrome
    let theme: FleckThemeSnapshot
    @ViewBuilder let content: (Item) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
      let view = Anchor()
      let coordinator = context.coordinator
      coordinator.anchor = view
      view.onLayout = { [weak coordinator] in coordinator?.schedule() }
      return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
      context.coordinator.source = self
      context.coordinator.schedule()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
      view.onLayout = nil
      coordinator.source = nil
      coordinator.dismiss(updateBinding: false)
    }

    final class Anchor: NSView {
      var onLayout: (() -> Void)?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
      }

      override func layout() {
        super.layout()
        onLayout?()
      }
    }

    @MainActor final class Coordinator {
      weak var anchor: Anchor?
      var source: NotesAnchoredPanel?
      private var shownItem: Item?
      private var panel: Panel?
      private var host: NSHostingController<Surface>?
      private var observations: [NSObjectProtocol] = []
      private var eventMonitor: Any?
      private var scheduled = false
      private var contentNeedsUpdate = true
      private var contentSize = NSSize.zero

      func schedule() {
        contentNeedsUpdate = true
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          scheduled = false
          reconcile()
        }
      }

      private func reconcile() {
        guard let source, let item = source.item else {
          dismiss(updateBinding: false)
          return
        }
        guard let anchor, let owner = anchor.window, owner.isVisible, owner.screen != nil,
          !anchor.bounds.isEmpty
        else {
          if panel != nil { dismiss(restoreFocus: false) }
          return
        }
        if let panel, shownItem == item, panel.parent === owner, let host {
          if contentNeedsUpdate {
            contentNeedsUpdate = false
            host.rootView = surface(source, item: item)
          }
          place()
          return
        }

        dismiss(updateBinding: false)
        let host = NSHostingController(rootView: surface(source, item: item))
        let size = host.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let panel = Panel(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.contentViewController = host
        self.panel = panel
        self.host = host
        shownItem = item
        contentSize = size
        contentNeedsUpdate = false
        place(relativeTo: owner)
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        track(owner)
      }

      private func surface(_ source: NotesAnchoredPanel, item: Item) -> Surface {
        Surface(
          content: source.content(item), chrome: source.chrome, theme: source.theme,
          uiFont: source.uiFont, font: source.font
        ) { [weak self] size in
          guard let self, shownItem == item, size.width > 0, size.height > 0, size != contentSize else { return }
          contentSize = size
          place()
        }
      }

      private func place(relativeTo initialOwner: NSWindow? = nil) {
        guard let panel, let anchor, let owner = initialOwner ?? panel.parent,
          let screen = owner.screen
        else { return }
        let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = NotesMenuPlacement.belowTrailing.frame(
          anchor: rect, menuSize: contentSize, screen: screen.visibleFrame
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
      }

      private func track(_ owner: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
          observations.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
          })
        }
        observations.append(center.addObserver(
          forName: NSWindow.willCloseNotification, object: owner, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
        observations.append(center.addObserver(
          forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
        observations.append(center.addObserver(
          forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, let panel = self.panel,
              !self.isInside(NSApp.keyWindow, panel: panel)
            else { return }
            self.dismiss(restoreFocus: false)
          }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
          [weak self] event in
          guard let self, let panel, !isInside(event.window, panel: panel) else { return event }
          let hitAnchor = anchor.map { view in
            event.window === view.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
          } ?? false
          dismiss(restoreFocus: hitAnchor)
          return hitAnchor ? nil : event
        }
      }

      private func isInside(_ window: NSWindow?, panel: NSWindow) -> Bool {
        var candidate = window
        while let window = candidate {
          if window === panel { return true }
          candidate = window.parent
        }
        return false
      }

      func dismiss(updateBinding: Bool = true, restoreFocus: Bool = true) {
        guard let panel else { return }
        let item = shownItem
        let owner = panel.parent
        let wasKey = panel.isKeyWindow
        self.panel = nil
        shownItem = nil
        if let eventMonitor {
          NSEvent.removeMonitor(eventMonitor)
          self.eventMonitor = nil
        }
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        host = nil
        panel.close()
        if restoreFocus, wasKey, let owner, owner.isVisible { owner.makeKey() }
        if updateBinding, let source, source.item == item { source.item = nil }
      }
    }

    private final class Panel: NSPanel {
      var onCancel: (() -> Void)?
      override var canBecomeKey: Bool { true }
      override var canBecomeMain: Bool { false }
      override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private struct Surface: View {
      let content: Content
      let chrome: NotesSolidChrome
      let theme: FleckThemeSnapshot
      let uiFont: FleckUIFont
      let font: Font?
      let onSize: (NSSize) -> Void

      var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        content
          .fixedSize()
          .background(chrome.popoverSurface, in: shape)
          .clipShape(shape)
          .overlay { shape.strokeBorder(chrome.popoverOutline).allowsHitTesting(false) }
          .environment(\.fleckThemeSnapshot, theme)
          .environment(\.colorScheme, theme.colorScheme)
          .environment(\.fleckUIFont, uiFont)
          .environment(\.font, font)
          .foregroundStyle(theme.color(.textPrimary))
          .tint(theme.color(.accent))
          .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
      }
    }
  }

  extension View {
    @ViewBuilder func notesAnchoredPanel<PanelContent: View>(
      isPresented: Binding<Bool>, chrome: NotesSolidChrome, theme: FleckThemeSnapshot,
      nativeEdge: Edge = .top,
      @ViewBuilder content: @escaping () -> PanelContent
    ) -> some View {
      if chrome.isActive {
        let item: Binding<Bool?> = Binding {
          isPresented.wrappedValue ? true : nil
        } set: {
          isPresented.wrappedValue = $0 != nil
        }
        background {
          NotesAnchoredPanel(item: item, chrome: chrome, theme: theme) { _ in content() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      } else {
        popover(isPresented: isPresented, arrowEdge: nativeEdge) {
          content().fleckPopoverTheme(theme)
        }
      }
    }
  }
#endif
