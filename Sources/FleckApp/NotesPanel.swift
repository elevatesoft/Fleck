#if os(macOS)
  import AppKit
  import SwiftUI
  import FleckCore
  import UniformTypeIdentifiers

  enum NoteTabInk {
    static let selectedCapsuleOpacity = 0.22
    static let solidCapsuleOutset: CGFloat = 2

    static func selectedCapsuleFill(tabColor: NSColor, surfaceColor: NSColor) -> NSColor {
      FleckColorContrast.composite(
        tabColor.withAlphaComponent(selectedCapsuleOpacity),
        over: surfaceColor
      )
    }

    static func selectedLabelColor(tabColor: NSColor, surfaceColor: NSColor) -> NSColor {
      let fill = selectedCapsuleFill(tabColor: tabColor, surfaceColor: surfaceColor)
      return FleckColorContrast.accessibleForeground(.white, against: fill)
    }
  }

  enum FolderDragPayload {
    static let noteType = UTType(exportedAs: "com.harryjin.fleck.local-note", conformingTo: .data)
    static let folderType = UTType(exportedAs: "com.harryjin.fleck.local-folder", conformingTo: .data)

    struct FolderValue: Codable, Equatable {
      let folderID: UUID
      let sessionID: UUID
    }

    static func noteProvider(source: NoteDropSource) -> NSItemProvider {
      let data = try! JSONEncoder().encode(source)
      let provider = NSItemProvider()
      provider.registerDataRepresentation(forTypeIdentifier: noteType.identifier, visibility: .ownProcess) {
        completion in
        completion(data, nil)
        return nil
      }
      return provider
    }

    static func notePasteboardItem(source: NoteDropSource) -> NSPasteboardItem {
      let item = NSPasteboardItem()
      item.setData(try! JSONEncoder().encode(source), forType: .init(noteType.identifier))
      return item
    }

    static func noteValue(from data: Data) -> NoteDropSource? {
      try? JSONDecoder().decode(NoteDropSource.self, from: data)
    }

    static func folderProvider(folderID: UUID, sessionID: UUID = UUID()) -> NSItemProvider {
      let provider = NSItemProvider()
      let data = try! JSONEncoder().encode(FolderValue(folderID: folderID, sessionID: sessionID))
      provider.registerDataRepresentation(forTypeIdentifier: folderType.identifier, visibility: .ownProcess) {
        completion in
        completion(data, nil)
        return nil
      }
      return provider
    }

    static func folderValue(from data: Data) -> FolderValue? {
      try? JSONDecoder().decode(FolderValue.self, from: data)
    }

    static func folderID(from data: Data) -> UUID? {
      folderValue(from: data)?.folderID
    }
  }

  // Keep the accepted transaction alive independently of drag presentation.
  // Payload authentication and native move completion may arrive in either order.
  @MainActor final class ReorderDropSession: ObservableObject {
    let id: UUID
    let type: UTType
    private let sourceID: UUID
    private let noteSource: NoteDropSource?
    private let matches: (Data) -> Bool
    private enum Phase { case dragging, ended, cancelled, committed }
    @Published private var phase = Phase.dragging
    private var accepted = false
    private var pendingCommit: (() -> Void)?

    var canAcceptDrop: Bool { phase == .dragging && !accepted }
    var isDragging: Bool { phase == .dragging }

    init(source: NoteDropSource) {
      id = source.dragSessionID
      type = FolderDragPayload.noteType
      sourceID = source.noteID
      noteSource = source
      matches = { FolderDragPayload.noteValue(from: $0) == source }
    }

    init(folder: FolderDragPayload.FolderValue) {
      id = folder.sessionID
      type = FolderDragPayload.folderType
      sourceID = folder.folderID
      noteSource = nil
      matches = { FolderDragPayload.folderValue(from: $0) == folder }
    }

    func acceptDrop(from providers: [NSItemProvider], commit: @escaping () -> Void) -> Task<Void, Never>? {
      guard canAcceptDrop,
        let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) })
      else { return nil }
      accepted = true
      return Task { @MainActor in
        guard phase != .cancelled else { return }
        let results = AsyncStream<Data?> { continuation in
          provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            continuation.yield(error == nil ? data : nil)
            continuation.finish()
          }
        }
        for await data in results {
          guard let data else { cancel(); return }
          _ = stage(data: data, commit: commit)
          return
        }
      }
    }

    func acceptDrop(data: Data, commit: @escaping () -> Void) -> Bool {
      guard canAcceptDrop else { return false }
      accepted = true
      return stage(data: data, commit: commit)
    }

    func acceptReorder(from providers: [NSItemProvider], interaction: ReorderInteraction,
      currentIDs: @escaping () -> [UUID], currentPinnedIDs: @escaping () -> Set<UUID>,
      move: @escaping (UUID, Int) -> Void) -> Task<Void, Never>? {
      guard let commit = reorderCommit(interaction: interaction, currentIDs: currentIDs,
        currentPinnedIDs: currentPinnedIDs, move: move) else { return nil }
      return acceptDrop(from: providers, commit: commit)
    }

    func acceptReorder(data: Data, interaction: ReorderInteraction,
      currentIDs: @escaping () -> [UUID], currentPinnedIDs: @escaping () -> Set<UUID>,
      move: @escaping (UUID, Int) -> Void) -> Bool {
      guard let commit = reorderCommit(interaction: interaction, currentIDs: currentIDs,
        currentPinnedIDs: currentPinnedIDs, move: move) else { return false }
      return acceptDrop(data: data, commit: commit)
    }

    private func reorderCommit(interaction: ReorderInteraction,
      currentIDs: @escaping () -> [UUID], currentPinnedIDs: @escaping () -> Set<UUID>,
      move: @escaping (UUID, Int) -> Void) -> (() -> Void)? {
      var proposal = interaction
      guard proposal.sessionID == id, proposal.sourceID == sourceID, let targetID = proposal.targetID,
        proposal.pinnedIDs.contains(proposal.sourceID) == proposal.pinnedIDs.contains(targetID),
        proposal.pinnedIDs == currentPinnedIDs(),
        let destination = proposal.consume(currentIDs: currentIDs())
      else { return nil }
      return {
        guard proposal.originalIDs == currentIDs(), proposal.pinnedIDs == currentPinnedIDs() else { return }
        move(proposal.sourceID, destination)
      }
    }

    func acceptNoteTransfer(from providers: [NSItemProvider], source: NoteDropSource,
      targetFolderID: UUID?, currentSourceNotes: @escaping () -> [Note],
      validTargetFolderIDs: @escaping () -> Set<UUID>,
      move: @escaping (NoteDropSource, UUID?) -> Bool) -> Task<Void, Never>? {
      guard let commit = noteTransferCommit(source: source, targetFolderID: targetFolderID,
        currentSourceNotes: currentSourceNotes, validTargetFolderIDs: validTargetFolderIDs,
        move: move) else { return nil }
      return acceptDrop(from: providers, commit: commit)
    }

    func acceptNoteTransfer(data: Data, source: NoteDropSource,
      targetFolderID: UUID?, currentSourceNotes: @escaping () -> [Note],
      validTargetFolderIDs: @escaping () -> Set<UUID>,
      move: @escaping (NoteDropSource, UUID?) -> Bool) -> Bool {
      guard let commit = noteTransferCommit(source: source, targetFolderID: targetFolderID,
        currentSourceNotes: currentSourceNotes, validTargetFolderIDs: validTargetFolderIDs,
        move: move) else { return false }
      return acceptDrop(data: data, commit: commit)
    }

    private func noteTransferCommit(source: NoteDropSource, targetFolderID: UUID?,
      currentSourceNotes: @escaping () -> [Note],
      validTargetFolderIDs: @escaping () -> Set<UUID>,
      move: @escaping (NoteDropSource, UUID?) -> Bool) -> (() -> Void)? {
      let originalNotes = currentSourceNotes()
      guard noteSource == source,
        NoteDropPresentation.isValidTarget(draggedSource: source, targetFolderID: targetFolderID,
          notes: originalNotes, validTargetFolderIDs: validTargetFolderIDs())
      else { return nil }
      let originalIDs = originalNotes.map(\.id)
      let originalPins = Set(originalNotes.filter(\.isPinned).map(\.id))
      return {
        let notes = currentSourceNotes()
        guard notes.map(\.id) == originalIDs, Set(notes.filter(\.isPinned).map(\.id)) == originalPins
        else { return }
        _ = NoteDropPresentation.performLocalDrop(draggedSource: source, providerSource: source,
          targetFolderID: targetFolderID, notes: notes, validTargetFolderIDs: validTargetFolderIDs(),
          move: move)
      }
    }

    func end(operation: NSDragOperation) {
      guard phase == .dragging else { return }
      guard operation == .move else { cancel(); return }
      phase = .ended
      commitIfReady()
    }

    func cancel() {
      guard phase != .committed else { return }
      phase = .cancelled
      pendingCommit = nil
    }

    private func stage(data: Data, commit: @escaping () -> Void) -> Bool {
      guard phase != .cancelled && phase != .committed else { return false }
      guard matches(data) else { cancel(); return false }
      pendingCommit = commit
      commitIfReady()
      return true
    }

    private func commitIfReady() {
      guard phase == .ended, let commit = pendingCommit else { return }
      phase = .committed
      pendingCommit = nil
      commit()
    }
  }

  struct NoteDropSource: Codable, Equatable {
    let noteID: UUID
    let sourceFolderID: UUID?
    let dragSessionID: UUID

    init(noteID: UUID, sourceFolderID: UUID?, dragSessionID: UUID = UUID()) {
      self.noteID = noteID
      self.sourceFolderID = sourceFolderID
      self.dragSessionID = dragSessionID
    }
  }

  // The proposal is disposable; only consume on a validated native drop.
  struct ReorderInteraction: Equatable {
    let sourceID: UUID
    let originalIDs: [UUID]
    let sessionID = UUID()
    var pinnedIDs: Set<UUID> = []
    private(set) var targetID: UUID?
    private(set) var after = false
    private(set) var destination: Int?

    mutating func propose(over targetID: UUID, after: Bool, currentIDs: [UUID]) {
      clearTarget()
      guard originalIDs == currentIDs, currentIDs.contains(sourceID), sourceID != targetID,
        let target = currentIDs.filter({ $0 != sourceID }).firstIndex(of: targetID)
      else { return }
      self.targetID = targetID
      self.after = after
      destination = target + (after ? 1 : 0)
    }

    mutating func clearTarget() {
      targetID = nil
      destination = nil
    }

    mutating func consume(currentIDs: [UUID]) -> Int? {
      defer { clearTarget() }
      guard currentIDs == originalIDs, currentIDs.contains(sourceID) else { return nil }
      return destination
    }
  }

  enum NoteDropPresentation {
    static func performLocalDrop(
      draggedSource: NoteDropSource?, providerSource: NoteDropSource?,
      targetFolderID: UUID?, notes: [Note], validTargetFolderIDs: Set<UUID>,
      move: (NoteDropSource, UUID?) -> Bool
    ) -> Bool {
      guard let draggedSource, draggedSource == providerSource,
        isValidTarget(draggedSource: draggedSource, targetFolderID: targetFolderID,
          notes: notes, validTargetFolderIDs: validTargetFolderIDs)
      else { return false }
      return move(draggedSource, targetFolderID)
    }

    static func isValidTarget(
      draggedSource: NoteDropSource?,
      targetFolderID: UUID?,
      notes: [Note],
      validTargetFolderIDs: Set<UUID>
    ) -> Bool {
      guard let draggedSource,
        let note = notes.first(where: { $0.id == draggedSource.noteID }),
        note.folderID == draggedSource.sourceFolderID
      else { return false }
      if let targetFolderID, !validTargetFolderIDs.contains(targetFolderID) {
        return false
      }
      return draggedSource.sourceFolderID != targetFolderID
    }
  }

  @MainActor enum MenuWindowDropGeometry {
    static func targetRect(for view: NSView, in window: NSWindow) -> NSRect? {
      guard view.window === window, !view.bounds.isEmpty, let contentView = window.contentView else {
        return nil
      }
      var rect = view.convert(view.bounds, to: nil)
      var ancestor = view.superview
      while let current = ancestor {
        if let clip = current as? NSClipView {
          rect = rect.intersection(clip.convert(clip.bounds, to: nil))
        }
        ancestor = current.superview
      }
      rect = rect.intersection(contentView.convert(contentView.bounds, to: nil))
      return rect.isNull || rect.isEmpty ? nil : rect
    }
  }

  @MainActor final class MenuWindowNoteDropCoordinator: ObservableObject {
    private final class FolderTarget {
      weak var view: NSView?
      let id = UUID()
      let canAccept: (Data) -> Bool
      let perform: (Data) -> Bool
      let setHovered: (Bool) -> Void

      init(view: NSView, canAccept: @escaping (Data) -> Bool,
        perform: @escaping (Data) -> Bool, setHovered: @escaping (Bool) -> Void) {
        self.view = view
        self.canAccept = canAccept
        self.perform = perform
        self.setHovered = setHovered
      }
    }

    private enum Target: Equatable {
      case tab
      case folder(UUID)
    }

    private weak var window: NSWindow?
    private var proxy: MenuWindowDropProxy?
    private var source: NoteDropSource?
    private var session: ReorderDropSession?
    private weak var tabController: FluidTabDragController?
    private var folderTargets: [FolderTarget] = []
    private var target: Target?
    private var performedSequence: Int?

    func activate(source: NoteDropSource, session: ReorderDropSession,
      tabController: FluidTabDragController?) {
      clearTarget()
      self.source = source
      self.session = session
      self.tabController = tabController
      performedSequence = nil
    }

    func deactivate(sessionID: UUID) {
      guard source?.dragSessionID == sessionID else { return }
      clearTarget()
      source = nil
      session = nil
      tabController = nil
      performedSequence = nil
    }

    @discardableResult
    func registerFolderTarget(view: NSView, canAccept: @escaping (Data) -> Bool,
      perform: @escaping (Data) -> Bool, setHovered: @escaping (Bool) -> Void) -> UUID {
      let registration = FolderTarget(view: view, canAccept: canAccept,
        perform: perform, setHovered: setHovered)
      folderTargets.append(registration)
      return registration.id
    }

    func unregisterFolderTarget(_ id: UUID) {
      if target == .folder(id) { transition(to: nil) }
      folderTargets.removeAll { $0.id == id }
    }

    func attach(to window: NSWindow) {
      if self.window === window, window.delegate === proxy { return }
      detach()
      let proxy = MenuWindowDropProxy(originalDelegate: window.delegate, coordinator: self)
      self.window = window
      self.proxy = proxy
      window.registerForDraggedTypes([.init(FolderDragPayload.noteType.identifier)])
      window.delegate = proxy
    }

    func detach() {
      clearTarget()
      if let window, window.delegate === proxy {
        window.delegate = proxy?.originalDelegate
      }
      window = nil
      proxy = nil
    }

    func detach(from window: NSWindow) {
      guard self.window === window else { return }
      detach()
    }

    fileprivate func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard let data = validData(sender), let window else {
        clearTarget()
        return []
      }
      folderTargets.removeAll { $0.view == nil }
      if let folder = folderTargets.last(where: { registration in
        guard let view = registration.view,
          let rect = MenuWindowDropGeometry.targetRect(for: view, in: window)
        else { return false }
        return rect.contains(sender.draggingLocation) && registration.canAccept(data)
      }) {
        transition(to: .folder(folder.id))
        return .move
      }
      if let tabController, let view = tabController.view,
        let rect = MenuWindowDropGeometry.targetRect(for: view, in: window),
        rect.contains(sender.draggingLocation) {
        transition(to: .tab)
        return tabController.operation(sender)
      }
      clearTarget()
      return []
    }

    fileprivate func prepare(_ sender: any NSDraggingInfo) -> Bool {
      guard operation(sender) == .move else { return false }
      sender.animatesToDestination = false
      return true
    }

    fileprivate func perform(_ sender: any NSDraggingInfo) -> Bool {
      guard performedSequence != sender.draggingSequenceNumber,
        operation(sender) == .move,
        let data = validData(sender)
      else { return false }
      let accepted: Bool
      switch target {
      case .tab:
        accepted = tabController?.perform(sender) ?? false
      case .folder(let id):
        accepted = folderTargets.first(where: { $0.id == id })?.perform(data) ?? false
      case nil:
        accepted = false
      }
      if accepted { performedSequence = sender.draggingSequenceNumber }
      return accepted
    }

    fileprivate func clearTarget() { transition(to: nil) }

    private func validData(_ sender: any NSDraggingInfo) -> Data? {
      guard sender.draggingDestinationWindow === window,
        sender.draggingSource is ReorderNativeSource,
        let source, let session,
        session.id == source.dragSessionID,
        session.canAcceptDrop,
        let data = sender.draggingPasteboard.data(
          forType: .init(FolderDragPayload.noteType.identifier)
        ),
        FolderDragPayload.noteValue(from: data) == source
      else { return nil }
      return data
    }

    private func transition(to next: Target?) {
      guard target != next else { return }
      switch target {
      case .tab:
        tabController?.exited()
      case .folder(let id):
        folderTargets.first(where: { $0.id == id })?.setHovered(false)
      case nil:
        break
      }
      target = next
      if case .folder(let id) = next {
        folderTargets.first(where: { $0.id == id })?.setHovered(true)
      }
    }
  }

  final class MenuWindowDropProxy: NSObject, NSWindowDelegate {
    fileprivate weak var originalDelegate: (any NSWindowDelegate)?
    private unowned let coordinator: MenuWindowNoteDropCoordinator
    private var foreignOperation: (sequence: Int, operation: NSDragOperation)?

    init(originalDelegate: (any NSWindowDelegate)?, coordinator: MenuWindowNoteDropCoordinator) {
      self.originalDelegate = originalDelegate
      self.coordinator = coordinator
    }

    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
      if originalDelegate?.responds(to: selector) == true { return originalDelegate }
      return super.forwardingTarget(for: selector)
    }

    @MainActor @objc func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard !isFleckNote(sender) else { return coordinator.operation(sender) }
      let operation = (originalDelegate as AnyObject?)?.draggingEntered?(sender) ?? []
      foreignOperation = (sender.draggingSequenceNumber, operation)
      return operation
    }

    @MainActor @objc func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard !isFleckNote(sender) else { return coordinator.operation(sender) }
      return (originalDelegate as AnyObject?)?.draggingUpdated?(sender)
        ?? (foreignOperation?.sequence == sender.draggingSequenceNumber
          ? foreignOperation?.operation : nil)
        ?? []
    }

    @MainActor @objc func draggingExited(_ sender: (any NSDraggingInfo)?) {
      if let sender {
        if isFleckNote(sender) {
          coordinator.clearTarget()
        } else {
          (originalDelegate as AnyObject?)?.draggingExited?(sender)
        }
      } else {
        coordinator.clearTarget()
        (originalDelegate as AnyObject?)?.draggingExited?(nil)
      }
      foreignOperation = nil
    }

    @MainActor @objc func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      guard !isFleckNote(sender) else { return coordinator.prepare(sender) }
      return (originalDelegate as AnyObject?)?.prepareForDragOperation?(sender) ?? true
    }

    @MainActor @objc func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      guard !isFleckNote(sender) else { return coordinator.perform(sender) }
      return (originalDelegate as AnyObject?)?.performDragOperation?(sender) ?? false
    }

    @MainActor @objc func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
      if let sender {
        if isFleckNote(sender) {
          coordinator.clearTarget()
        } else {
          (originalDelegate as AnyObject?)?.concludeDragOperation?(sender)
        }
      } else {
        coordinator.clearTarget()
        (originalDelegate as AnyObject?)?.concludeDragOperation?(nil)
      }
      foreignOperation = nil
    }

    @MainActor @objc func draggingEnded(_ sender: any NSDraggingInfo) {
      if isFleckNote(sender) {
        coordinator.clearTarget()
      } else {
        (originalDelegate as AnyObject?)?.draggingEnded?(sender)
      }
      foreignOperation = nil
    }

    @MainActor private func isFleckNote(_ sender: any NSDraggingInfo) -> Bool {
      sender.draggingPasteboard.availableType(
        from: [.init(FolderDragPayload.noteType.identifier)]
      ) != nil
    }

  }

  private struct MenuWindowDropInstaller: NSViewRepresentable {
    let coordinator: MenuWindowNoteDropCoordinator

    func makeNSView(context: Context) -> HostView {
      HostView(coordinator: coordinator)
    }

    func updateNSView(_ view: HostView, context: Context) {
      view.installIfNeeded()
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
      view.uninstall()
    }

    final class HostView: NSView {
      private let coordinator: MenuWindowNoteDropCoordinator
      private weak var installedWindow: NSWindow?

      init(coordinator: MenuWindowNoteDropCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
      }

      required init?(coder: NSCoder) { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfNeeded()
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func installIfNeeded() {
        guard installedWindow !== window else {
          if let window { coordinator.attach(to: window) }
          return
        }
        if let installedWindow { coordinator.detach(from: installedWindow) }
        installedWindow = window
        if let window { coordinator.attach(to: window) }
      }

      func uninstall() {
        if let installedWindow { coordinator.detach(from: installedWindow) }
        installedWindow = nil
      }
    }
  }

  private struct MenuWindowDropInstallation: ViewModifier {
    let coordinator: MenuWindowNoteDropCoordinator
    let enabled: Bool

    func body(content: Content) -> some View {
      content.background {
        if enabled {
          MenuWindowDropInstaller(coordinator: coordinator)
            .frame(width: 0, height: 0)
        }
      }
    }
  }

  private struct MenuWindowFolderDropAnchor: NSViewRepresentable {
    let coordinator: MenuWindowNoteDropCoordinator
    let canAccept: (Data) -> Bool
    let perform: (Data) -> Bool
    let setHovered: (Bool) -> Void

    func makeNSView(context: Context) -> HostView {
      let view = HostView()
      view.owner = coordinator
      view.update(canAccept: canAccept, perform: perform, setHovered: setHovered)
      view.registrationID = coordinator.registerFolderTarget(
        view: view,
        canAccept: { [weak view] in view?.canAccept($0) ?? false },
        perform: { [weak view] in view?.perform($0) ?? false },
        setHovered: { [weak view] in view?.setHovered($0) }
      )
      return view
    }

    func updateNSView(_ view: HostView, context: Context) {
      view.update(canAccept: canAccept, perform: perform, setHovered: setHovered)
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
      guard let owner = view.owner, let registrationID = view.registrationID else { return }
      owner.unregisterFolderTarget(registrationID)
    }

    final class HostView: NSView {
      weak var owner: MenuWindowNoteDropCoordinator?
      var registrationID: UUID?
      var canAccept: (Data) -> Bool = { _ in false }
      var perform: (Data) -> Bool = { _ in false }
      var setHovered: (Bool) -> Void = { _ in }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func update(canAccept: @escaping (Data) -> Bool,
        perform: @escaping (Data) -> Bool, setHovered: @escaping (Bool) -> Void) {
        self.canAccept = canAccept
        self.perform = perform
        self.setHovered = setHovered
      }
    }
  }

  enum FolderNavigatorFocus {
    static func nextIndex(
      currentIndex: Int,
      direction: MoveCommandDirection,
      count: Int
    ) -> Int {
      guard count > 0 else { return 0 }
      let offset: Int
      switch direction {
      case .up: offset = -1
      case .down: offset = 1
      default: return currentIndex
      }
      return min(max(currentIndex + offset, 0), count - 1)
    }
  }

  enum TabDragReorder {
    static func partitionLocalDestination(
      draggedID: UUID,
      absoluteDestination: Int,
      visibleNotes: [Note]
    ) -> Int? {
      guard let draggedNote = visibleNotes.first(where: { $0.id == draggedID }) else {
        return nil
      }
      let notesAfterRemoval = visibleNotes.filter { $0.id != draggedID }
      let insertion = min(max(absoluteDestination, 0), notesAfterRemoval.count)
      return notesAfterRemoval.prefix(insertion).reduce(into: 0) { count, note in
        if note.isPinned == draggedNote.isPinned {
          count += 1
        }
      }
    }

  }

  enum TabOverflowPresentation {
    static let tabOverflowRailWidth: CGFloat = 56

    static func overflows(contentWidth: CGFloat, totalStripWidth: CGFloat) -> Bool {
      contentWidth > totalStripWidth
    }

    static func tabViewportWidth(totalStripWidth: CGFloat, showsOverflow: Bool) -> CGFloat {
      max(0, totalStripWidth - (showsOverflow ? tabOverflowRailWidth : 0))
    }
  }

  private struct TabStripContentWidthObserver: NSViewRepresentable {
    let onWidthChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WidthObserverView {
      return WidthObserverView(onWidthChange: onWidthChange)
    }

    func updateNSView(_ view: WidthObserverView, context: Context) {
      view.onWidthChange = onWidthChange
    }

    final class WidthObserverView: NSView {
      var onWidthChange: (CGFloat) -> Void
      private var measuredWidth: CGFloat?

      init(onWidthChange: @escaping (CGFloat) -> Void) {
        self.onWidthChange = onWidthChange
        super.init(frame: .zero)
      }

      required init?(coder: NSCoder) { nil }

      override func layout() {
        super.layout()
        let width = bounds.width
        guard width.isFinite, measuredWidth != width else { return }
        measuredWidth = width
        DispatchQueue.main.async { [weak self] in
          guard let self, self.measuredWidth == width else { return }
          self.onWidthChange(width)
        }
      }
    }
  }

  enum TabTitlePresentation {
    static let maximumWidth: CGFloat = 160
    static let fadeWidth: CGFloat = 12
  }

  struct NoteTabTitleFadeMask: View {
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
      HStack(spacing: 0) {
        Color.white
        LinearGradient(
          colors: [.white, .clear],
          startPoint: UnitPoint(x: layoutDirection == .leftToRight ? 0 : 1, y: 0.5),
          endPoint: UnitPoint(x: layoutDirection == .leftToRight ? 1 : 0, y: 0.5)
        )
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: TabTitlePresentation.fadeWidth)
      }
      .frame(width: TabTitlePresentation.maximumWidth, alignment: .leading)
    }
  }

  private struct NoteTabTitleLabel: View {
    let title: String

    var body: some View {
      ViewThatFits(in: .horizontal) {
        Text(title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        Text(title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .frame(width: TabTitlePresentation.maximumWidth, alignment: .leading)
          .clipped()
          .mask { NoteTabTitleFadeMask() }
      }
      .frame(maxWidth: TabTitlePresentation.maximumWidth, alignment: .leading)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityLabel(title)
    }
  }

  enum FontSizeSubmission {
    static func requestedSize(
      for text: String,
      currentSize: CGFloat?,
      isMixed: Bool
    ) -> CGFloat? {
      guard let size = Double(text), size.isFinite, (1...512).contains(size) else { return nil }
      let requestedSize = CGFloat(size)
      guard isMixed || requestedSize != currentSize else { return nil }
      return requestedSize
    }
  }

  enum NotesPanelSizing: Equatable {
    case storedPreferences
    case container

    static func storedSize(preferred: CGSize, available: CGSize) -> CGSize {
      CGSize(
        width: min(preferred.width, max(available.width, 0)),
        height: min(preferred.height, max(available.height, 0))
      )
    }
  }

  enum FleckChromeMaterialPolicy: Equatable {
    case liquidGlass
    case legacyMaterial
    case opaque

    static func resolve(
      appearance: FleckChromeAppearance,
      supportsLiquidGlass: Bool,
      reduceTransparency: Bool,
      increasedContrast: Bool
    ) -> Self {
      if appearance == .solid || reduceTransparency || increasedContrast { return .opaque }
      return supportsLiquidGlass ? .liquidGlass : .legacyMaterial
    }

    static func current(
      appearance: FleckChromeAppearance,
      reduceTransparency: Bool,
      increasedContrast: Bool
    ) -> Self {
      resolve(
        appearance: appearance,
        supportsLiquidGlass: supportsLiquidGlass,
        reduceTransparency: reduceTransparency,
        increasedContrast: increasedContrast
      )
    }

    private static var supportsLiquidGlass: Bool {
      if #available(macOS 26, *) { true } else { false }
    }
  }

  private struct FleckChromeAppearanceKey: EnvironmentKey {
    static let defaultValue = FleckChromeAppearance.solid
  }

  extension EnvironmentValues {
    var fleckChromeAppearance: FleckChromeAppearance {
      get { self[FleckChromeAppearanceKey.self] }
      set { self[FleckChromeAppearanceKey.self] = newValue }
    }
  }

  enum NotesPanelBannerCategory: Hashable {
    case captureFailure
    case agentChange
  }

  enum NotesPanelBannerOccurrence: Hashable {
    case captureFailure(message: String, actionPanes: [DictationPrivacyPane])
    case agentChange(changeID: UUID, count: Int)

    var category: NotesPanelBannerCategory {
      switch self {
      case .captureFailure: .captureFailure
      case .agentChange: .agentChange
      }
    }
  }

  enum NotesPanelBannerPolicy {
    static func activeOccurrences(
      captureFailure: NotesPanelBannerOccurrence?,
      routineRecoveryAction _: DictationCapsuleAction?,
      agentChange: NotesPanelBannerOccurrence?
    ) -> Set<NotesPanelBannerOccurrence> {
      Set([captureFailure, agentChange].compactMap { $0 })
    }
  }

  struct NotesPanelBannerDismissalState: Equatable {
    private var dismissedOccurrences = Set<NotesPanelBannerOccurrence>()

    mutating func reconcile(
      activeOccurrences: Set<NotesPanelBannerOccurrence>
    ) {
      dismissedOccurrences.formIntersection(activeOccurrences)
    }

    mutating func forgetDismissedOccurrences(
      in category: NotesPanelBannerCategory
    ) {
      dismissedOccurrences = dismissedOccurrences.filter {
        $0.category != category
      }
    }

    mutating func dismiss(_ occurrence: NotesPanelBannerOccurrence) {
      dismissedOccurrences.insert(occurrence)
    }

    func isPresented(_ occurrence: NotesPanelBannerOccurrence) -> Bool {
      !dismissedOccurrences.contains(occurrence)
    }
  }

  struct NotesPanelBannerCloseButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
      .help("Dismiss \(label)")
      .accessibilityLabel("Dismiss \(label)")
    }
  }

  struct NotesPanel: View {
    private enum EditorFocus: Hashable {
      case title
      case body
    }

    private enum TabScrollTarget: Hashable {
      case leading
      case trailing
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.menuPanelGeometryStore) private var menuPanelGeometryStore
    @ObservedObject var dictationRuntime: DictationRuntime
    let isPinned: Bool
    let sizing: NotesPanelSizing
    @StateObject private var editorCommands = EditorCommands()
    @StateObject private var searchController: WorkspaceSearchController
    @StateObject private var noteLinkPickerController: NoteLinkPickerController
    @StateObject private var backlinkController: BacklinkController
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isShowingTrash = false
    @State private var isShowingDictationHistory = false
    @State private var isShowingAgentActivity = false
    @State private var isShowingActivityInbox = false
    @State private var notePendingDeletion: Note?
    @State private var folderPendingDeletion: Folder?
    @State private var dontAskAgainForDeletion = false
    @State private var exportDocument: NoteFileDocument?
    @State private var exportType = NoteFileDocument.markdownContentType
    @State private var exportFilename = "Untitled.md"
    @State private var noteDropSource: NoteDropSource?
    @State private var reorderDragSession: ReorderDropSession?
    @StateObject private var fluidTabDrag = FluidTabDragController()
    @StateObject private var menuWindowDrop = MenuWindowNoteDropCoordinator()
    @StateObject private var menuPanelResize = MenuPanelResizeController()
    @State private var tabStripContentWidth: CGFloat = 0
    @State private var tabColorPickerNoteID: UUID?
    @State private var activeFolderID: UUID?
    @State private var bannerDismissalState = NotesPanelBannerDismissalState()
    @State private var restoreEditorFocusAfterHide = false
    @State private var searchPointerActivationPending = false
    @State private var pendingNoteLinkTarget: EditorNoteLinkTarget?
    @FocusState private var editorFocus: EditorFocus?
    private let filePicker: NoteFilePicker

    init(
      dictationRuntime: DictationRuntime,
      isPinned: Bool = false,
      sizing: NotesPanelSizing = .storedPreferences,
      editorCommands: EditorCommands? = nil,
      searchController: WorkspaceSearchController? = nil,
      noteLinkPickerController: NoteLinkPickerController? = nil,
      backlinkController: BacklinkController? = nil,
      filePicker: NoteFilePicker = .live
    ) {
      let searchController = searchController ?? WorkspaceSearchController()
      let noteLinkPickerController = noteLinkPickerController ?? NoteLinkPickerController()
      self.dictationRuntime = dictationRuntime
      self.isPinned = isPinned
      self.sizing = sizing
      _editorCommands = StateObject(wrappedValue: editorCommands ?? EditorCommands())
      _searchController = StateObject(wrappedValue: searchController)
      _noteLinkPickerController = StateObject(wrappedValue: noteLinkPickerController)
      _backlinkController = StateObject(wrappedValue: backlinkController ?? BacklinkController())
      self.filePicker = filePicker
      noteLinkPickerController.setPresentationGuard { !searchController.isPresented }
    }

    private var chromeMaterialPolicy: FleckChromeMaterialPolicy {
      FleckChromeMaterialPolicy.current(
        appearance: appState.preferences.chromeAppearance,
        reduceTransparency: reduceTransparency,
        increasedContrast: colorSchemeContrast == .increased
      )
    }

    private var solidChrome: NotesSolidChrome {
      NotesSolidChrome(theme: theme, appearance: appState.preferences.chromeAppearance)
    }

    private var navigationDivider: some View {
      Group {
        if solidChrome.isActive {
          Rectangle().fill(solidChrome.notesNavigationDivider).frame(height: 1)
        } else {
          Divider().opacity(0.35)
        }
      }
      .accessibilityHidden(true)
    }

    var body: some View {
      ZStack {
        if isPinned {
          PinnedWritingSurface(color: theme.nsColor(.editorOpaque))
            .accessibilityHidden(true)
        }
        VStack(spacing: 0) {
          if let migrationError = appState.startupMigrationError {
            migrationFailure(migrationError)
          } else {
            if isPinned {
              pinnedNavigationChrome
            } else {
              header
              folderNavigator
              tabStrip
              navigationDivider
            }
            if let failure = dictationRuntime.captureFailure {
              let occurrence = NotesPanelBannerOccurrence.captureFailure(
                message: failure.message,
                actionPanes: failure.actions.map(\.pane)
              )
              if bannerDismissalState.isPresented(occurrence) {
                if solidChrome.isActive {
                  darkSolidCaptureFailure(failure, occurrence: occurrence)
                  .padding(solidChrome.windowEdgePadding(
                    horizontal: 11, after: menuPanelResizePaintInsets
                  ))
                  .padding(.vertical, 7)
                } else {
                  HStack(spacing: 8) {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                      .fleckUIFont(.caption)
                    Spacer()
                    ForEach(failure.actions, id: \.pane) { action in
                      Button(action.title) {
                        dictationRuntime.openSystemSettings(action)
                      }
                      .accessibilityLabel(action.title)
                    }
                    NotesPanelBannerCloseButton(
                      label: "dictation capture failure",
                      action: { dismissBanner(occurrence) }
                    )
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .foregroundStyle(theme.color(.textPrimary))
                  .background(theme.color(.raised))
                  .accessibilityElement(children: .contain)
                  .accessibilityLabel("Dictation unavailable")
                }
              }
            }
            if !solidChrome.isActive || !isEditorVisible {
              agentUpdateBanner
            }
            scopedEditor
              .frame(minHeight: 80)
              .layoutPriority(1)
            if let error = appState.saveError,
              !(solidChrome.isActive && isShowingTrash && appState.trashUpdateError != nil)
            {
              if solidChrome.isActive {
                paperSaveError(error)
              } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("Could not save: \(error)")
                    .fleckUIFont(.caption)
                    .foregroundStyle(theme.color(.error))
                    .frame(maxWidth: .infinity, alignment: .leading)
                  if appState.canRetryPersistenceSave {
                    Button("Retry") {
                      appState.retryPersistenceSave()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .accessibilityIdentifier("save-error-retry-button")
                    .help("Try saving these changes again")
                  }
                }
                .padding(8)
              }
            }
            if let error = appState.noteFileReferenceError {
              if solidChrome.isActive {
                NotesBannerNotice(icon: .system("paperclip"), message: error, isError: true)
                  .padding(solidChrome.windowEdgePadding(
                    horizontal: 11, bottom: 4, after: menuPanelResizePaintInsets
                  ))
              } else {
                Text(error)
                  .fleckUIFont(.caption)
                  .foregroundStyle(theme.color(.error))
                  .padding(8)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
        .allowsHitTesting(!searchController.isPresented)
        .allowsHitTesting(!isBlockingOverlayPresented)
        .disabled(searchController.isPresented)
        .disabled(isBlockingOverlayPresented)
        .accessibilityHidden(searchController.isPresented)
        .accessibilityHidden(isBlockingOverlayPresented)
      }
      .overlay {
        ZStack {
          if isShowingTrash {
            TrashPanelOverlay(
              onDone: { isShowingTrash = false }
            )
            .transition(
              .opacity.combined(
                with: .scale(scale: reduceMotion ? 1 : 0.985)
              )
            )
          }

          if !isPinned && isShowingAgentActivity {
            agentActivityOverlay
          }

          if let folderPendingDeletion {
            FolderDeleteConfirmationOverlay(
              folder: folderPendingDeletion,
              onCancel: { self.folderPendingDeletion = nil },
              onConfirm: { confirmFolderDeletion(folderPendingDeletion) }
            )
            .transition(
              .opacity.combined(
                with: .scale(scale: reduceMotion ? 1 : 0.985)
              )
            )
          }

          if let notePendingDeletion {
            DeleteConfirmationOverlay(
              note: notePendingDeletion,
              dontAskAgain: $dontAskAgainForDeletion,
              onCancel: {
                self.notePendingDeletion = nil
                self.dontAskAgainForDeletion = false
              },
              onConfirm: { confirmDeletion(notePendingDeletion) }
            )
            .transition(
              .opacity.combined(
                with: .scale(scale: reduceMotion ? 1 : 0.985)
              )
            )
          }
        }
        .animation(motion.standard, value: isShowingTrash)
        .animation(motion.standard, value: folderPendingDeletion?.id)
        .animation(motion.standard, value: notePendingDeletion?.id)
      }
      .overlay {
        ZStack {
          if searchController.isPresented && !noteLinkPickerController.isPresented {
            WorkspaceSearchView(
              controller: searchController,
              notes: appState.workspace.notes,
              accent: theme.color(.accent),
              presentationID: searchController.presentationID,
              reduceMotion: reduceMotion,
              currentNoteIDs: {
                Set(appState.workspace.notes.map(\.id))
              },
              onActivate: activateWorkspaceSearchResult,
              onDismiss: dismissWorkspaceSearch
            )
            .id(searchController.presentationID)
            .zIndex(2)
            .transition(workspaceSearchPresentationTransition)
          }
        }
      }
      .overlay {
        if noteLinkPickerController.isPresented {
          NoteLinkPickerView(
            controller: noteLinkPickerController,
            notes: appState.workspace.notes,
            foldersByID: folderNamesByID,
            accent: theme.color(.accent),
            currentNoteIDs: { Set(appState.workspace.notes.map(\.id)) },
            currentSource: {
              guard let source = visibleSelectedNote else { return nil }
              return (source.id, source.revision)
            },
            onChoose: insertNoteLink
          )
          .zIndex(3)
        }
      }
      .clipped()
      .contentShape(Rectangle())
      .opacity(menuPanelBodyIsPainted ? 1 : 0)
      .padding(menuPanelResizePaintInsets)
      .frame(
        minWidth: storedPanelSize?.width,
        maxWidth: sizing == .container ? .infinity : storedPanelSize?.width,
        minHeight: storedPanelSize?.height,
        maxHeight: sizing == .container ? .infinity : storedPanelSize?.height
      )
      .background {
        if !isPinned {
          Group {
            switch chromeMaterialPolicy {
            case .liquidGlass:
              Rectangle()
                .fill(.regularMaterial)
                .opacity(appState.preferences.panelOpacity)
            case .legacyMaterial:
              Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(appState.preferences.panelOpacity)
            case .opaque:
              Rectangle().fill(theme.color(solidChrome.isActive ? .editorOpaque : .window))
            }
          }
          .opacity(menuPanelBodyIsPainted ? 1 : 0)
        }
      }
      .modifier(NotesSolidWindowOutline(
        outline: solidChrome.isActive && !isPinned && menuPanelBodyIsPainted
          ? solidChrome.outline : nil
      ))
      .background {
        if solidChrome.isActive, isEditorVisible,
          dictationRuntime.isInputMonitoringNoticeDismissed,
          dictationRuntime.modifierMonitorState == .unauthorized
        {
          NotesModifierAttemptObserver(onPress: dictationRuntime.observeLocalModifierAttempt)
        }
      }
      .overlay {
        if !isPinned, sizing == .storedPreferences {
          if let reorderDragSession {
            ReorderAwareMenuPanelResizeInstaller(
              dragSession: reorderDragSession,
              controller: menuPanelResize,
              geometryStore: menuPanelGeometryStore,
              preferredSize: preferredMenuPanelSize,
              canResize: allowsMenuPanelResize,
              onCommit: saveMenuPanelSize
            )
          } else {
            MenuPanelResizeInstaller(
              controller: menuPanelResize,
              geometryStore: menuPanelGeometryStore,
              preferredSize: preferredMenuPanelSize,
              canResize: allowsMenuPanelResize,
              onCommit: saveMenuPanelSize
            )
          }
        }
      }
      .background(
        FleckWindowTheme(
          usesOpaqueBackground: isPinned
            || (sizing == .container && chromeMaterialPolicy == .opaque)
        )
        .frame(width: 0, height: 0)
      )
      .tint(theme.color(.accent))
      .foregroundStyle(theme.color(.textPrimary))
      .environment(\.fleckChromeAppearance, appState.preferences.chromeAppearance)
      .background(
        ShortcutMonitor(
          shortcuts: appState.preferences.shortcuts,
          windowCloseHandling: solidChrome.isActive
            ? (isPinned ? .closeOwningWindow : .reserved) : .standard,
          action: performShortcut
        )
          .frame(width: 0, height: 0)
      )
      .background(
        WorkspaceSearchWindowReader(controller: searchController)
          .frame(width: 0, height: 0)
      )
      .background(
        NoteLinkPickerWindowReader(controller: noteLinkPickerController)
          .frame(width: 0, height: 0)
      )
      .modifier(MenuWindowDropInstallation(
        coordinator: menuWindowDrop,
        enabled: !isPinned
      ))
      .onChange(of: activeBannerOccurrences, initial: true) { _, occurrences in
        bannerDismissalState.reconcile(activeOccurrences: occurrences)
      }
      .onChange(of: appState.workspace.selectedNoteID, initial: true) { oldValue, newValue in
        if oldValue != newValue {
          pendingNoteLinkTarget?.cancel()
          pendingNoteLinkTarget = nil
          editorCommands.invalidateEditorSession()
        }
        appState.refreshSelectedNoteFileReferences()
        editorFocus = nil
        synchronizeBodyCommandGuard()
      }
      .onChange(of: isBlockingOverlayPresented, initial: true) { _, _ in
        synchronizeBodyCommandGuard()
      }
      .onChange(of: editorFocus, initial: true) { _, _ in
        synchronizeBodyCommandGuard()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        appState.refreshSelectedNoteFileReferences()
      }
      .onReceive(dictationRuntime.$captureFailure) { failure in
        guard failure == nil else { return }
        bannerDismissalState.forgetDismissedOccurrences(in: .captureFailure)
      }
      .fileImporter(
        isPresented: $isImporting,
        allowedContentTypes: [.plainText, NoteFileDocument.markdownContentType],
        allowsMultipleSelection: true,
        onCompletion: importFiles
      )
      .fileExporter(
        isPresented: $isExporting,
        document: exportDocument,
        contentType: exportType,
        defaultFilename: exportFilename
      ) { result in
        if case .failure(let error) = result {
          appState.saveError = "Export failed: \(error.localizedDescription)"
        }
      }
      .sheet(isPresented: $isShowingDictationHistory) {
        DictationHistoryView(
          history: dictationRuntime.historyController,
          notesChrome: solidChrome,
          liveNoteIDs: Set(appState.workspace.notes.map(\.id)),
          onOpenDestination: openHistoryDestination
        )
      }
      .sheet(isPresented: agentActivitySheetPresentation) {
        agentActivityContent
          .frame(minWidth: 520, minHeight: 380)
      }
      .onAppear {
        dictationRuntime.registerEditor(editorCommands)
      }
      .onDisappear {
        fluidTabDrag.cancel()
        if let source = noteDropSource {
          menuWindowDrop.deactivate(sessionID: source.dragSessionID)
        }
        noteDropSource = nil
        dictationRuntime.unregisterEditor(editorCommands)
      }
      .task {
        await appState.waitUntilInitialLoad()
        guard !Task.isCancelled else { return }
        activeFolderID = appState.folderScopeForSelectedNote()
        backlinkController.refresh(liveNotes: appState.workspace.notes)
      }
      .onChange(of: appState.workspace.notes) { _, notes in
        backlinkController.refresh(liveNotes: notes)
      }
      .onChange(of: searchController.isPresented) { _, isPresented in
        if !isPresented {
          searchPointerActivationPending = false
        }
        if isPresented, noteLinkPickerController.isPresented {
          dismissWorkspaceSearch()
        }
      }
      .onChange(of: noteLinkPickerController.isPresented) { _, isPresented in
        if isPresented, searchController.isPresented {
          dismissWorkspaceSearch()
        }
      }
      .onChange(of: appState.workspace.folders) { _, folders in
        guard let activeFolderID,
          !folders.contains(where: { $0.id == activeFolderID })
        else { return }
        self.activeFolderID = nil
      }
      .onChange(of: appState.workspace.selectedNoteID) { oldID, newID in
        guard isShowingTrash, oldID != newID else { return }
        if let newID {
          activeFolderID = appState.folderID(for: newID)
        } else {
          activeFolderID = nil
        }
      }
    }

    private var pinnedNavigationChrome: some View {
      VStack(spacing: 0) {
        header
        folderNavigator
        tabStrip
        navigationDivider
      }
      .modifier(PinnedNavigationChromeSurface())
    }

    private var modifierShortcutPresentation: DictationModifierSettingsPresentation {
      dictationRuntime.modifierShortcutPresentation
    }

    private var paperModifierShortcutRecovery: some View {
      let presentation = modifierShortcutPresentation
      let actions = presentation.recoveryButtonTitle.map {
        [NotesBannerNotice.Action(title: $0, perform: performShortcutRecovery)]
      } ?? []
      return NotesBannerNotice(
        icon: .system("keyboard"),
        message: presentation.statusCopy,
        detail: presentation.detailCopy,
        actions: actions,
        onDismiss: presentation.recoveryAction == .enableInputMonitoring
          ? .init(title: "Dismiss Input Monitoring notice",
                  perform: dictationRuntime.dismissInputMonitoringNotice)
          : nil
      )
      .accessibilityLabel(presentation.capsuleAccessibilityLabel)
      .padding(solidChrome.windowEdgePadding(horizontal: 11, after: menuPanelResizePaintInsets))
      .padding(.vertical, 7)
    }

    private func performShortcutRecovery() {
      Task { @MainActor in
        await dictationRuntime.performModifierShortcutRecovery {
          dictationRuntime.openSystemSettings($0)
        }
      }
    }

    private var activeBannerOccurrences: Set<NotesPanelBannerOccurrence> {
      let captureFailure = dictationRuntime.captureFailure.map {
        NotesPanelBannerOccurrence.captureFailure(
          message: $0.message,
          actionPanes: $0.actions.map(\.pane)
        )
      }
      return NotesPanelBannerPolicy.activeOccurrences(
        captureFailure: captureFailure,
        routineRecoveryAction: dictationRuntime.recoveryAction,
        agentChange: agentBannerOccurrence
      )
    }

    private var agentBannerOccurrence: NotesPanelBannerOccurrence? {
      appState.agentBannerPresentation.map {
        .agentChange(changeID: $0.feedback.changeID, count: $0.count)
      }
    }

    private var presentedAgentBannerOccurrence: NotesPanelBannerOccurrence? {
      guard let occurrence = agentBannerOccurrence,
        bannerDismissalState.isPresented(occurrence)
      else { return nil }
      return occurrence
    }

    private func dismissBanner(_ occurrence: NotesPanelBannerOccurrence) {
      withTransaction(Transaction(animation: nil)) {
        bannerDismissalState.dismiss(occurrence)
      }
    }

    @ViewBuilder
    private func darkSolidCaptureFailure(
      _ failure: DictationCaptureFailurePresentation, occurrence: NotesPanelBannerOccurrence
    ) -> some View {
      if failure.actions.count == 2,
        let microphone = failure.actions.first(where: { $0.pane == .microphone }),
        let speech = failure.actions.first(where: { $0.pane == .speechRecognition })
      {
        NotesDictationPermissionsBanner(
          openMicrophone: { dictationRuntime.openSystemSettings(microphone) },
          openSpeechRecognition: { dictationRuntime.openSystemSettings(speech) },
          dismiss: { dismissBanner(occurrence) }
        )
      } else {
        NotesBannerNotice(
          icon: .system(captureFailureIcon(failure)),
          message: failure.message,
          actions: failure.actions.map { action in
            .init(title: action.title) { dictationRuntime.openSystemSettings(action) }
          },
          onDismiss: .init(title: "Dismiss dictation capture failure") {
            dismissBanner(occurrence)
          }
        )
        .accessibilityLabel("Dictation unavailable")
      }
    }

    private func captureFailureIcon(_ failure: DictationCaptureFailurePresentation) -> String {
      switch failure.actions.first?.pane {
      case .microphone: "mic"
      case .speechRecognition: "text.bubble"
      case .inputMonitoring, nil: "exclamationmark.triangle"
      }
    }

    private func paperSaveError(_ message: String) -> some View {
      let canRetry = appState.canRetryPersistenceSave
      return NotesBannerNotice(
        icon: canRetry ? .save : .system(appState.saveErrorIsUnavailableNoteLink ? "link" : "exclamationmark.triangle"),
        message: "Could not save: \(message)",
        isError: true,
        actions: canRetry ? [
          .init(title: "Retry", identifier: "save-error-retry-button", help: "Try saving these changes again") {
            appState.retryPersistenceSave()
          }
        ] : []
      )
      .padding(solidChrome.windowEdgePadding(
        horizontal: 11, bottom: 4, after: menuPanelResizePaintInsets
      ))
    }

    @ViewBuilder
    private var agentUpdateBanner: some View {
      if let banner = appState.agentBannerPresentation {
        if let occurrence = presentedAgentBannerOccurrence {
          AgentChangeBanner(
            presentation: banner,
            motion: motion,
            usesDarkSolidNotesChrome: solidChrome.isActive,
            onUndo: { Task { await appState.undoLatestAgentChange() } },
            onDoNotShowAgain: {
              appState.updatePreferences { $0.showAgentUpdateBanners = false }
            },
            onDismiss: { dismissBanner(occurrence) }
          )
          .animation(motion.quick, value: banner)
        }
      }
    }

    private func migrationFailure(
      _ error: FleckProductMigrationError
    ) -> some View {
      VStack(spacing: 12) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.system(size: 28))
          .foregroundStyle(theme.color(.error))
        Text("Fleck needs your help")
          .fleckUIFont(.headline)
        Text(
          "Fleck found both legacy and current note data. Nothing was changed. "
            + "Close Fleck and resolve the two Application Support folders "
            + "before reopening it."
        )
        .fleckUIFont(.callout)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.color(.textSecondary))
        Text(String(describing: error))
          .font(.caption2.monospaced())
          .foregroundStyle(theme.color(.caption))
          .textSelection(.enabled)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Fleck data migration requires attention")
    }

    private var header: some View {
      let backlinkEntries = backlinkController.incoming(to: appState.workspace.selectedNoteID)
      return HStack(spacing: 4) {
        if solidChrome.isActive {
          if case .image(let mark) = FleckMark.load(template: true) {
            Image(nsImage: mark)
              .frame(width: 18, height: 18)
              .accessibilityHidden(true)
          }
        } else {
          AgentActivityIndicator(presentation: appState.agentActivityIndicator) {
            isShowingAgentActivity = true
          }
        }
        Spacer()
        SaveFeedbackView(
          presentation: appState.saveFeedback,
          motion: motion,
          usesDarkSolidNotesChrome: solidChrome.isActive
        )
        .padding(.trailing, solidChrome.isActive ? 5 : 0)
        .padding(.bottom, solidChrome.isActive ? 2 : 0)
        if solidChrome.isActive {
          agentActivityInboxButton
        }
        Button {
          backlinkController.toggleDisclosure()
        } label: {
          notesHeaderIcon(systemName: "link", paperGlyph: .backlinks)
            .frame(width: 28, height: 28)
        }
        .accessibilityIdentifier("backlinks-toolbar-button")
        .accessibilityLabel("Backlinks")
        .accessibilityValue(
          backlinkEntries.count == 1
            ? "1 backlink"
            : "\(backlinkEntries.count) backlinks"
        )
        .accessibilityHint("Show notes linking here")
        .help("Backlinks")
        .notesAnchoredPanel(isPresented: backlinksPopoverPresentation, chrome: solidChrome, theme: theme) {
          BacklinksView(
            entries: backlinkEntries,
            foldersByID: folderNamesByID,
            usesSolidNotesChrome: solidChrome.isActive,
            onOpen: { noteID in
              if backlinkController.isExpanded {
                backlinkController.toggleDisclosure()
              }
              openNoteLink(noteID)
            }
          )
          .frame(
            width: 320,
            height: solidChrome.isActive && backlinkEntries.isEmpty ? 76 : nil,
            alignment: .topLeading
          )
        }
        Button {
          let pointerActivation = searchPointerActivationPending
          searchPointerActivationPending = false
          guard !pointerActivation else { return }
          Task { @MainActor in
            await Task.yield()
            guard !searchController.isPresented else { return }
            presentWorkspaceSearch(activation: .keyboard)
          }
        } label: {
          notesHeaderIcon(systemName: "magnifyingglass", paperGlyph: .search)
            .frame(width: 28, height: 28)
            .opacity(searchController.isPresented ? 0 : 1)
            .accessibilityHidden(true)
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityLabel("Search notes")
        .accessibilityHint("Search note titles and bodies")
        .help("Search notes (⌘F)")
        .simultaneousGesture(
          TapGesture().onEnded {
            guard !noteLinkPickerController.isPresented else { return }
            searchPointerActivationPending = true
            presentWorkspaceSearch(activation: .pointer)
          }
        )
        Button {
          appState.addNote(inFolderID: activeFolderID)
        } label: {
          notesHeaderIcon(systemName: "plus", paperGlyph: .plus)
            .frame(width: 28, height: 28)
        }
        .keyboardShortcut("t", modifiers: .command)
        .accessibilityLabel("New note")
        .help("New note")

        if isPinned && solidChrome.isActive {
          Button {
            dismissWindow(id: "pinned-notes")
          } label: {
            Image(systemName: "pin.fill")
              .frame(width: 28, height: 28)
              .foregroundStyle(.tint)
          }
          .accessibilityLabel("Unpin Notes window")
          .accessibilityValue("Pinned")
          .help("Unpin and close this window")
        } else if isPinned {
          Image(systemName: "pin.fill")
            .frame(width: 28, height: 28)
            .foregroundStyle(.tint)
            .accessibilityLabel("Pinned")
            .help("This window stays open until you close it")
        } else {
          Button {
            presentPersistentWindow {
              openWindow(id: "pinned-notes")
            }
          } label: {
            notesHeaderIcon(systemName: "pin", paperGlyph: .pin)
              .frame(width: 28, height: 28)
          }
          .accessibilityLabel("Pin notes on screen")
          .help("Pin notes on screen")
        }

        Button {
          if reduceMotion {
            appState.updatePreferences { $0.showFormattingBar.toggle() }
          } else {
            withAnimation(motion.quick) {
              appState.updatePreferences { $0.showFormattingBar.toggle() }
            }
          }
        } label: {
          notesHeaderIcon(systemName: "chevron.up", paperGlyph: .chevron)
            .frame(width: 28, height: 28)
            .rotationEffect(
              .degrees(appState.preferences.showFormattingBar ? 0 : 180)
            )
            .animation(
              reduceMotion ? nil : motion.quick,
              value: appState.preferences.showFormattingBar
            )
        }
        .accessibilityLabel(
          appState.preferences.showFormattingBar
            ? "Hide Editor toolbar"
            : "Show Editor toolbar"
        )
        .help(
          appState.preferences.showFormattingBar
            ? "Hide Editor toolbar"
            : "Show Editor toolbar"
        )

        notesOptionsMenu

        Button {
          presentPersistentWindow {
            openSettings()
          }
        } label: {
          notesHeaderIcon(systemName: "slider.horizontal.3", paperGlyph: .sliders)
            .frame(width: 28, height: 28)
        }
        .accessibilityLabel("Customize")
        .help("Customize")
      }
      .buttonStyle(FleckQuietButtonStyle(cornerRadius: 6))
      .focusEffectDisabled(!solidChrome.isActive)
      .padding(.horizontal, solidChrome.isActive ? 15 : 14)
      .padding(.top, solidChrome.isActive ? 7 : 11)
      .padding(.bottom, solidChrome.isActive ? 5 : 11)
    }

    @ViewBuilder
    private func notesHeaderIcon(systemName: String, paperGlyph: NotesPaperIcon.Glyph) -> some View {
      if solidChrome.isActive {
        NotesPaperIcon(glyph: paperGlyph)
      } else {
        Image(systemName: systemName)
      }
    }

    private var folderNavigator: some View {
      FolderNavigator(
        draggedSource: $noteDropSource,
        dragSession: $reorderDragSession,
        menuWindowDrop: isPinned ? nil : menuWindowDrop,
        activeFolderID: activeFolderID,
        onSelect: selectFolder,
        onDelete: { folderPendingDeletion = $0 },
        onOpenTrash: { isShowingTrash = true }
      )
      .environmentObject(appState)
    }

    private func selectFolder(_ folderID: UUID?) {
      guard folderID == nil || appState.workspace.folders.contains(where: { $0.id == folderID })
      else { return }
      activeFolderID = folderID
      let visible = appState.visibleNotes(in: folderID)
      guard !visible.contains(where: { $0.id == appState.workspace.selectedNoteID }),
        let first = visible.first
      else { return }
      _ = activateNoteAndScope(first.id)
    }

    private func activateNoteAndScope(_ noteID: UUID) -> Bool {
      guard appState.workspace.notes.contains(where: { $0.id == noteID }) else {
        return false
      }
      activeFolderID = appState.folderID(for: noteID)
      if appState.workspace.selectedNoteID != noteID {
        appState.select(noteID)
      }
      return true
    }

    private func deleteFolder(_ folderID: UUID) {
      let currentFolderID = activeFolderID
      if currentFolderID == folderID {
        activeFolderID = nil
      }
      do {
        try appState.deleteFolder(id: folderID, activeFolderID: currentFolderID)
        appState.folderActionSucceeded(folderID: folderID)
      } catch {
        if currentFolderID == folderID {
          activeFolderID = folderID
        }
        appState.folderActionFailed(
          "Could not update folder: \(String(describing: error))",
          folderID: folderID
        )
      }
    }

    private func confirmFolderDeletion(_ folder: Folder) {
      folderPendingDeletion = nil
      deleteFolder(folder.id)
    }

    private var tabStrip: some View {
      // Paper’s 40-point strip includes its one-point bottom divider.
      let stripHeight: CGFloat = solidChrome.isActive ? 39 : 37
      let capsuleOutset = solidChrome.isActive ? NoteTabInk.solidCapsuleOutset : 0
      return ScrollViewReader { scrollProxy in
        GeometryReader { proxy in
          let hasOverflow = TabOverflowPresentation.overflows(
            contentWidth: tabStripContentWidth,
            totalStripWidth: proxy.size.width
          )
          let tabViewportWidth = TabOverflowPresentation.tabViewportWidth(
            totalStripWidth: proxy.size.width,
            showsOverflow: hasOverflow
          )
        HStack(spacing: 0) {
          ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 0) {
                Color.clear
                  .frame(width: 0, height: 0)
                  .id(TabScrollTarget.leading)
                FluidTabStripHost(
                  controller: fluidTabDrag,
                  selectedID: appState.workspace.selectedNoteID,
                  selectedColor: visibleNotes.first(where: {
                    $0.id == appState.workspace.selectedNoteID
                  }).map { Color(nsColor: selectedTabCapsuleFill(for: $0)) },
                  hoverColor: solidChrome.isActive
                    ? Color.primary.opacity(theme.increasedContrast ? 0.18 : 0.08) : nil,
                  reduceMotion: reduceMotion,
                  capsuleOutset: capsuleOutset
                ) {
                HStack(spacing: 6) {
                ForEach(visibleNotes) { note in
            Button {
              _ = activateNoteAndScope(note.id)
            } label: {
              HStack(spacing: 4) {
                if note.isPinned {
                  Image(systemName: "pin.fill")
                    .font(.caption2)
                }
                NoteTabTitleLabel(title: note.displayTitle)
                if appState.isSharedWithAnyActiveProfile(note.id) {
                  Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .accessibilityLabel(AgentSharingPresentation.sharedBadgeAccessibilityLabel)
                }
              }
              .foregroundStyle(note.id == appState.workspace.selectedNoteID
                ? selectedTabLabelInk(for: note)
                : theme.color(.textPrimary))
              .fleckUIFont(.body)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .frame(minHeight: solidChrome.isActive ? 28 : nil)
              .contentShape(Capsule())
              .background {
                if note.id != appState.workspace.selectedNoteID, note.tabColorHex != nil {
                  Capsule()
                    .inset(by: -capsuleOutset)
                    .fill(tabColor(for: note, opacity: 0.10))
                }
              }
            }
            .buttonStyle(.plain)
            .fleckHoverFill(
              in: Capsule().inset(by: -capsuleOutset),
              isAllowed: !solidChrome.isActive && note.id != appState.workspace.selectedNoteID
            )
            .accessibilityIdentifier("note-tab-\(note.id.uuidString)")
            .modifier(ReorderDragSource(begin: {
              let interaction = ReorderInteraction(sourceID: note.id, originalIDs: visibleNotes.map(\.id),
                pinnedIDs: Set(visibleNotes.filter(\.isPinned).map(\.id)))
              let source = NoteDropSource(
                noteID: note.id,
                sourceFolderID: note.folderID,
                dragSessionID: interaction.sessionID
              )
              let session = ReorderDropSession(source: source)
              reorderDragSession?.cancel()
              reorderDragSession = session
              noteDropSource = source
              fluidTabDrag.prepare(interaction: interaction, session: session,
                currentIDs: { appState.visibleNotes(in: note.folderID).map(\.id) },
                currentPins: { Set(appState.visibleNotes(in: note.folderID).filter(\.isPinned).map(\.id)) },
                move: { id, destination in
                  guard let localDestination = TabDragReorder.partitionLocalDestination(
                    draggedID: id, absoluteDestination: destination,
                    visibleNotes: appState.visibleNotes(in: note.folderID)) else { return }
                  _ = appState.moveNote(id, inFolderID: note.folderID, toVisibleIndex: localDestination)
                }, finish: { if noteDropSource == source { noteDropSource = nil } })
              if !isPinned {
                menuWindowDrop.activate(
                  source: source,
                  session: session,
                  tabController: fluidTabDrag
                )
              }
              return (FolderDragPayload.noteProvider(source: source),
                FolderDragPayload.notePasteboardItem(source: source), { operation in
                session.end(operation: operation)
                fluidTabDrag.ended(sessionID: session.id, operation: operation)
                if !isPinned { menuWindowDrop.deactivate(sessionID: session.id) }
                if noteDropSource == source { noteDropSource = nil }
              })
            }, began: { point in fluidTabDrag.began(at: point) }, moved: { point in fluidTabDrag.moved(to: point) },
              activate: { _ = activateNoteAndScope(note.id) }, noteID: note.id,
              displacement: fluidTabDrag.inside ? fluidTabDrag.preview?.offset(for: note.id) ?? 0 : 0,
              animatesDisplacement: !motion.reduceMotion && fluidTabDrag.animatesDisplacement))
            .transition(
              .opacity.combined(
                with: .offset(x: motion.offset)
              )
            )
            .contextMenu {
              Button(
                note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin"
              ) {
                guard isNoteVisible(note.id) else { return }
                appState.togglePinned(note.id)
              }
              Button("Move Left", systemImage: "arrow.left") {
                move(note, offset: -1)
              }
              Button("Move Right", systemImage: "arrow.right") {
                move(note, offset: 1)
              }
              let moveToFolder: (UUID?) -> Void = { destinationFolderID in
                guard isNoteVisible(note.id),
                  let currentNote = appState.workspace.notes.first(where: { $0.id == note.id })
                else { return }
                _ = appState.moveNote(
                  note.id,
                  fromFolderID: currentNote.folderID,
                  toFolderID: destinationFolderID,
                  activeFolderID: activeFolderID
                )
              }
              Menu("Move to Folder", systemImage: "folder") {
                Button {
                  moveToFolder(nil)
                } label: {
                  HStack {
                    Text("Unfiled")
                    if note.folderID == nil {
                      Spacer()
                      Image(systemName: "checkmark")
                    }
                  }
                }
                .disabled(note.folderID == nil)
                ForEach(appState.workspace.folders, id: \.id) { folder in
                  Button {
                    moveToFolder(folder.id)
                  } label: {
                    HStack {
                      Text(folder.name)
                      if note.folderID == folder.id {
                        Spacer()
                        Image(systemName: "checkmark")
                      }
                    }
                  }
                  .disabled(note.folderID == folder.id)
                }
              }
              Button("Tab Color...", systemImage: "paintpalette") {
                guard isNoteVisible(note.id) else { return }
                tabColorPickerNoteID = note.id
              }
              .accessibilityValue(tabColorAccessibilityValue(for: note.tabColorHex))
              Divider()
              Button("Move to Trash", systemImage: "trash", role: .destructive) {
                requestDeletion(note)
              }
            }
            .notesAnchoredPanel(
              isPresented: Binding(
                get: { tabColorPickerNoteID == note.id },
                set: { if !$0 { tabColorPickerNoteID = nil } }
              ),
              chrome: solidChrome,
              theme: theme,
              nativeEdge: .bottom
            ) {
              tabColorPicker(noteID: note.id)
            }
                }
              }
              .padding(.horizontal, solidChrome.isActive ? 13 : 12)
              .fixedSize(horizontal: true, vertical: false)
              .background {
                TabStripContentWidthObserver { width in
                  tabStripContentWidth = width
                }
              }
              .padding(.top, solidChrome.isActive ? 1 : 0)
              .frame(height: stripHeight, alignment: solidChrome.isActive ? .top : .center)
              .animation(motion.spatial, value: visibleNotes.map(\.id))
              .frame(minWidth: tabViewportWidth, alignment: .leading)
              }
              // The AppKit-hosted capsule otherwise sits three points below
              // Paper's optically aligned position in this fixed-height rail.
              .offset(y: solidChrome.isActive ? -3 : 0)
                Color.clear
                  .frame(width: 0, height: 0)
                  .id(TabScrollTarget.trailing)
              }
            }
          }
          .frame(width: tabViewportWidth, alignment: .leading)

          if hasOverflow {
            HStack(spacing: 0) {
              Button {
                scrollProxy.scrollTo(TabScrollTarget.leading, anchor: .leading)
              } label: {
                Image(systemName: "chevron.left")
                  .font(.caption)
                  .frame(width: 28, height: 28)
                  .frame(width: 28, height: stripHeight)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
              .accessibilityLabel("Reveal earlier tabs")
              .accessibilityIdentifier("note-tab-overflow-earlier")
              .help("Show earlier tabs")
              .disabled(visibleNotes.isEmpty)

              Button {
                scrollProxy.scrollTo(TabScrollTarget.trailing, anchor: .trailing)
              } label: {
                Image(systemName: "chevron.right")
                  .font(.caption)
                  .frame(width: 28, height: 28)
                  .frame(width: 28, height: stripHeight)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
              .accessibilityLabel("Reveal later tabs")
              .accessibilityIdentifier("note-tab-overflow-later")
              .help("Show later tabs")
              .disabled(visibleNotes.isEmpty)
            }
            .frame(
              width: TabOverflowPresentation.tabOverflowRailWidth,
              height: stripHeight,
              alignment: .center
            )
          }
        }
        .onChange(of: hasOverflow) { wasOverflowing, isOverflowing in
          if wasOverflowing && !isOverflowing {
            scrollProxy.scrollTo(TabScrollTarget.leading, anchor: .leading)
          }
        }
        }
        .frame(height: stripHeight)
      }
    }

    private var motion: AppMotion {
      AppMotion(reduceMotion: reduceMotion)
    }

    private var workspaceSearchPresentationTransition: AnyTransition {
      switch searchController.presentationKind {
      case .inline:
        return .opacity.combined(
          with: .scale(scale: 0.98, anchor: .topTrailing)
        )
      case .crossfade:
        return .opacity
      case .instant:
        return .identity
      }
    }

    private func presentWorkspaceSearch(activation: WorkspaceSearchActivation) {
      guard !noteLinkPickerController.isPresented else { return }
      let presentation = WorkspaceSearchPresentationKind.resolve(
        activation: activation,
        reduceMotion: reduceMotion
      )
      withAnimation(
        motion.presentationAnimation(for: presentation.interactionSource)
      ) {
        if presentation == .instant {
          searchController.present(for: appState.workspace.selectedNoteID)
        } else {
          searchController.present(
            for: appState.workspace.selectedNoteID,
            presentation: presentation
          )
        }
      }
    }

    private func dismissWorkspaceSearch() {
      guard searchController.isPresented else { return }
      withAnimation(
        searchController.presentationKind.usesAnimatedDismissal ? motion.quick : nil
      ) {
        searchController.dismiss()
      }
    }

    private func activateWorkspaceSearchResult(_ noteID: UUID) {
      guard activateNoteAndScope(noteID) else { return }
      let result = searchController.results.first { $0.noteID == noteID }
      let query = searchController.query
      searchController.setActivationFocusRestore {
        self.revealWorkspaceSearchMatch(result, query: query, noteID: noteID)
      }
    }

    private func revealWorkspaceSearchMatch(
      _ result: WorkspaceSearchResult?,
      query: String,
      noteID: UUID
    ) -> Bool {
      guard let note = visibleSelectedNote, note.id == noteID,
        let textView = editorCommands.textView,
        let window = textView.window,
        let contentView = window.contentView,
        textView.isDescendant(of: contentView)
      else { return false }
      if let range = result?.bodyMatchRange(in: note.body, query: query) {
        guard editorCommands.isShowingNoteBody(note.body) else { return false }
        editorCommands.revealNoteBodyRange(range, noteBody: note.body)
      }
      if window.firstResponder === textView { return true }
      _ = window.makeFirstResponder(textView)
      return window.firstResponder === textView
    }

    private var backlinksPopoverPresentation: Binding<Bool> {
      Binding(
        get: { backlinkController.isExpanded },
        set: { isPresented in
          guard backlinkController.isExpanded != isPresented else { return }
          backlinkController.toggleDisclosure()
        }
      )
    }

    private func tabColor(for note: Note, opacity: Double) -> Color {
      guard let hex = note.tabColorHex else {
        return theme.color(.accent).opacity(opacity)
      }
      let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
      guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else {
        return theme.color(.accent).opacity(opacity)
      }
      return (Color(hex: hex) ?? theme.color(.accent)).opacity(opacity)
    }

    private func selectedTabLabelInk(for note: Note) -> Color {
      if solidChrome.isActive, note.tabColorHex == nil {
        return theme.color(.textPrimary)
      }
      return Color(
        nsColor: NoteTabInk.selectedLabelColor(
          tabColor: NSColor(hex: note.tabColorHex) ?? theme.nsColor(.accent),
          surfaceColor: theme.nsColor(.window)
        )
      )
    }

    private func selectedTabCapsuleFill(for note: Note) -> NSColor {
      if solidChrome.isActive, note.tabColorHex == nil {
        return theme.nsColor(.selectionFill)
      }
      return NoteTabInk.selectedCapsuleFill(
        tabColor: NSColor(hex: note.tabColorHex) ?? theme.nsColor(.accent),
        surfaceColor: theme.nsColor(.window)
      )
    }

    @ViewBuilder
    private func tabColorPicker(noteID: UUID) -> some View {
      if let note = appState.workspace.notes.first(where: { $0.id == noteID }) {
        FleckColorPicker(
          currentHex: note.tabColorHex,
          currentLabel: tabColorAccessibilityValue(for: note.tabColorHex),
          resetTitle: "None",
          onCommit: { hex in commitTabColor(hex, for: noteID) },
          onCancel: { tabColorPickerNoteID = nil }
        )
      } else {
        EmptyView()
      }
    }

    private func commitTabColor(_ hex: String?, for noteID: UUID) {
      guard isNoteVisible(noteID), activateNoteAndScope(noteID) else {
        tabColorPickerNoteID = nil
        return
      }
      appState.setSelectedTabColor(hex)
      tabColorPickerNoteID = nil
    }

    private func tabColorAccessibilityValue(for hex: String?) -> String {
      guard let hex else { return "None" }
      return FleckPaletteOption.paletteName(for: NSColor(hex: hex)) ?? "Custom"
    }

    private func performShortcut(_ action: Shortcut.Action) {
      guard !isBlockingOverlayPresented else { return }
      switch action {
      case .togglePanel:
        NSApp.keyWindow?.orderOut(nil)
      case .newNote:
        appState.addNote(inFolderID: activeFolderID)
      case .closeNote:
        if let note = visibleSelectedNote {
          requestDeletion(note)
        }
      case .nextNote:
        appState.selectAdjacentNote(forward: true, inFolderID: activeFolderID)
      case .previousNote:
        appState.selectAdjacentNote(forward: false, inFolderID: activeFolderID)
      }
    }

    private func requestDeletion(_ note: Note) {
      guard isNoteVisible(note.id) else { return }
      if appState.preferences.confirmBeforeMovingNotesToTrash {
        dontAskAgainForDeletion = false
        notePendingDeletion = note
      } else {
        appState.moveToTrash(note.id, activeFolderID: activeFolderID)
      }
    }

    private func confirmDeletion(_ note: Note) {
      guard isNoteVisible(note.id) else {
        notePendingDeletion = nil
        dontAskAgainForDeletion = false
        return
      }
      let shouldSuppressConfirmation = dontAskAgainForDeletion
      _ = appState.moveToTrash(
        note.id,
        activeFolderID: activeFolderID,
        suppressConfirmation: shouldSuppressConfirmation
      )
      notePendingDeletion = nil
      dontAskAgainForDeletion = false
    }

    private func openHistoryDestination(_ noteID: UUID) {
      if activateNoteAndScope(noteID) {
        isShowingDictationHistory = false
      }
    }

    private func presentPersistentWindow(_ present: () -> Void) {
      NSApp.activate()
      present()
      DispatchQueue.main.async {
        NSApp.activate()
      }
    }

    private func move(_ note: Note, offset: Int) {
      guard isNoteVisible(note.id) else { return }
      guard let index = visibleNotes.firstIndex(where: { $0.id == note.id }) else {
        return
      }
      guard let localDestination = TabDragReorder.partitionLocalDestination(
        draggedID: note.id,
        absoluteDestination: index + offset,
        visibleNotes: visibleNotes
      ) else { return }
      _ = appState.moveNote(
        note.id,
        inFolderID: activeFolderID,
        toVisibleIndex: localDestination
      )
    }

    private var notesOptionsMenu: some View {
      let actions = notesOptionsActions
      let noteID = visibleSelectedNote?.id
      return Menu {
        ForEach(actions.indices, id: \.self) { index in
          if let action = actions[index] {
            Button {
              guard visibleSelectedNote?.id == noteID else { return }
              action.perform()
            } label: {
              if let symbol = action.symbol {
                Label(action.title, systemImage: symbol)
              } else {
                Text(action.title)
              }
            }
            .disabled(!action.isEnabled)
          } else {
            Divider()
          }
        }
      } label: {
        notesHeaderIcon(systemName: "ellipsis.circle", paperGlyph: .options)
          .frame(width: 28, height: 28)
          .fleckHoverFill(in: RoundedRectangle(cornerRadius: 6), isAllowed: solidChrome.isActive)
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .accessibilityLabel("Options")
      .help("Options")
    }

    private var notesOptionsActions: [NotesMenuAction?] {
      var actions: [NotesMenuAction?] = []
      if let note = visibleSelectedNote {
        actions += [
          NotesMenuAction(
            title: "Add File Shortcut…", symbol: "paperclip",
            isEnabled: appState.canAddFileReference(noteID: note.id)
          ) { chooseFile(for: note.id) },
          nil,
        ]
      }
      actions += [
        NotesMenuAction(title: "Import Text or Markdown…", symbol: "square.and.arrow.down") { isImporting = true },
        nil,
        NotesMenuAction(title: "Export Markdown…") { startExport(.markdown) },
        NotesMenuAction(title: "Export Plain Text…") { startExport(.plainText) },
        NotesMenuAction(title: "Export Rich Text…") { startExport(.richText) },
        nil,
        NotesMenuAction(title: "Trash…", symbol: "trash") { isShowingTrash = true },
        NotesMenuAction(title: "Dictation History", symbol: "waveform") { isShowingDictationHistory = true },
        NotesMenuAction(title: "Agent Activity", symbol: "clock.arrow.circlepath") { isShowingAgentActivity = true },
      ]
      return actions
    }

    private func startExport(_ format: NoteExportFormat) {
      guard let note = visibleSelectedNote else { return }
      let export = PreparedNoteFileExport(note: note, format: format)
      exportDocument = export.document
      exportFilename = export.filename
      exportType = export.type
      isExporting = true
    }

    private func importFiles(_ result: Result<[URL], Error>) {
      do {
        for url in try result.get() {
          let accessing = url.startAccessingSecurityScopedResource()
          defer { if accessing { url.stopAccessingSecurityScopedResource() } }
          let note = try NoteImport.note(
            from: Data(contentsOf: url),
            filename: url.lastPathComponent
          )
          appState.importNote(note, intoFolderID: activeFolderID)
        }
        appState.saveError = nil
      } catch {
        appState.saveError = "Import failed: \(error.localizedDescription)"
      }
    }

    private func chooseFile(for noteID: UUID) {
      guard appState.canAddFileReference(noteID: noteID) else { return }
      _ = filePicker.chooseFile { result in
        handleFilePickerResult(result) { url in
          Self.completeFileReferenceSelection(url, noteID: noteID, appState: appState)
        }
      }
    }

    private func handleFilePickerResult(
      _ result: NoteFilePicker.Result,
      accepted: (URL) -> Void
    ) {
      switch result {
      case let .accepted(url):
        accepted(url)
      case .cancelled:
        break
      case .aborted:
        appState.fileReferenceActionFailed("The file chooser could not be opened.")
      }
    }

    static func completeFileReferenceSelection(
      _ url: URL?,
      noteID: UUID,
      appState: AppState
    ) {
      guard let url else { return }
      appState.addFileReference(noteID: noteID, url: url)
    }

    private func openFileReference(_ referenceID: UUID) {
      guard let url = appState.resolveFileReference(referenceID: referenceID) else {
        return
      }
      let didAccess = url.startAccessingSecurityScopedResource()
      NSWorkspace.shared.open(
        url,
        configuration: NSWorkspace.OpenConfiguration()
      ) { _, error in
        Task { @MainActor in
          if didAccess {
            url.stopAccessingSecurityScopedResource()
          }
          if error != nil {
            appState.fileReferenceActionFailed("The file could not be opened.")
          }
        }
      }
    }

    private func revealFileReference(_ referenceID: UUID) {
      guard let url = appState.resolveFileReference(referenceID: referenceID) else {
        return
      }
      let didAccess = url.startAccessingSecurityScopedResource()
      NSWorkspace.shared.activateFileViewerSelecting([url])
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    private func locateFileReference(_ referenceID: UUID) {
      _ = filePicker.chooseFile { result in
        handleFilePickerResult(result) { url in
          Self.completeFileReferenceRelink(
            url,
            referenceID: referenceID,
            appState: appState
          )
        }
      }
    }

    static func completeFileReferenceRelink(
      _ url: URL?,
      referenceID: UUID,
      appState: AppState
    ) {
      guard let url else { return }
      appState.relinkFileReference(referenceID: referenceID, url: url)
    }

    static func fileReferenceUndoManager(commands: EditorCommands) -> UndoManager? {
      commands.activeUndoManager
    }

    private var isBlockingOverlayPresented: Bool {
      noteLinkPickerController.isPresented || isNonPickerBlockingOverlayPresented
    }

    private var isNonPickerBlockingOverlayPresented: Bool {
      searchController.isPresented
        || notePendingDeletion != nil || folderPendingDeletion != nil || isShowingTrash
        || isShowingAgentActivity
    }

    private var allowsMenuPanelResize: Bool {
      !isBlockingOverlayPresented
        && !isImporting
        && !isExporting
        && !isShowingDictationHistory
    }

    private var preferredMenuPanelSize: CGSize {
      CGSize(
        width: appState.preferences.panelWidth,
        height: appState.preferences.panelHeight
      )
    }

    private func saveMenuPanelSize(_ size: CGSize) {
      guard size.width.isFinite, size.height.isFinite,
        size.width >= MenuPanelResizeGeometry.minimumContentSize.width,
        size.height >= MenuPanelResizeGeometry.minimumContentSize.height,
        menuPanelResize.initialContentSize != size,
        preferredMenuPanelSize != size
      else { return }
      appState.updatePreferences {
        $0.panelWidth = size.width
        $0.panelHeight = size.height
      }
    }

    private var agentActivityInboxButton: some View {
      AgentActivityIndicator(presentation: appState.agentActivityIndicator, usesBell: true) {
        isShowingActivityInbox.toggle()
      }
      .notesAnchoredPanel(isPresented: $isShowingActivityInbox, chrome: solidChrome, theme: theme) {
        AgentActivityInboxView(
          chrome: solidChrome,
          onOpenHistory: {
            isShowingActivityInbox = false
            isShowingAgentActivity = true
          },
          onOpenNote: { noteID in
            if activateNoteAndScope(noteID) {
              isShowingActivityInbox = false
            }
          }
        )
        .environmentObject(appState)
      }
      .onDisappear { isShowingActivityInbox = false }
    }

    private var agentActivitySheetPresentation: Binding<Bool> {
      Binding(
        get: { isPinned && isShowingAgentActivity },
        set: { isShowingAgentActivity = $0 }
      )
    }

    private var agentActivityContent: some View {
      AgentActivityView(
        notesChrome: solidChrome.isActive ? solidChrome : nil,
        onOpenNote: { noteID in
          if activateNoteAndScope(noteID) {
            isShowingAgentActivity = false
          }
        },
        onDismiss: { isShowingAgentActivity = false }
      )
      .environmentObject(appState)
    }

    private var agentActivityOverlay: some View {
      let chrome = solidChrome
      let shape = RoundedRectangle(cornerRadius: 14)
      return ZStack {
        Color.black.opacity(0.28)
          .ignoresSafeArea()
          .accessibilityHidden(true)

        agentActivityContent
          .frame(maxWidth: 520, maxHeight: 400)
          .background {
            if !chrome.isActive {
              RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.color(.card))
            }
          }
          .clipShape(shape)
          .overlay {
            if chrome.isActive {
              shape.strokeBorder(chrome.outline, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
          }
          .shadow(radius: 20, y: 8)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Agent Activity")
          .padding(8)
      }
    }

    private var folderNamesByID: [UUID: String] {
      Dictionary(uniqueKeysWithValues: appState.workspace.folders.map { ($0.id, $0.name) })
    }

    private func insertNoteLink(targetID: UUID, replacing range: NSRange) {
      let insertionTarget = pendingNoteLinkTarget
      pendingNoteLinkTarget = nil
      guard !noteLinkPickerController.isPresented,
        !isNonPickerBlockingOverlayPresented,
        !dictationRuntime.canCancel,
        !editorCommands.isFocusedDictationActive,
        editorFocus != .title,
        let insertionTarget,
        insertionTarget.range == range,
        insertionTarget.isValidAfterPickerDismissal(
          note: visibleSelectedNote,
          isEditorVisible: isEditorVisible,
          commands: editorCommands
        ),
        let target = appState.workspace.notes.first(where: { $0.id == targetID }),
        let textView = editorCommands.textView
      else { return }

      synchronizeBodyCommandGuard()
      textView.isEditable = true
      textView.isSelectable = true
      guard editorCommands.canPerformBodyCommand else { return }
      _ = insertionTarget.apply(
        label: target.displayTitle,
        targetNoteID: target.id,
        commands: editorCommands
      )
    }

    private func openNoteLink(_ noteID: UUID) {
      guard appState.workspace.notes.contains(where: { $0.id == noteID }) else {
        appState.reportUnavailableNoteLink()
        return
      }
      guard activateNoteAndScope(noteID) else {
        appState.reportUnavailableNoteLink()
        return
      }
      DispatchQueue.main.async {
        guard self.visibleSelectedNote?.id == noteID,
          let textView = self.editorCommands.textView,
          let window = textView.window
        else { return }
        _ = window.makeFirstResponder(textView)
      }
    }

    private var visibleNotes: [Note] {
      appState.visibleNotes(in: activeFolderID)
    }

    private var visibleSelectedNote: Note? {
      guard let selectedID = appState.workspace.selectedNoteID else { return nil }
      return visibleNotes.first(where: { $0.id == selectedID })
    }

    private func isNoteVisible(_ noteID: UUID) -> Bool {
      visibleNotes.contains(where: { $0.id == noteID })
    }

    private var isEditorVisible: Bool {
      guard let selectedID = appState.workspace.selectedNoteID else { return false }
      return visibleNotes.contains(where: { $0.id == selectedID })
    }

    @ViewBuilder
    private var scopedEditor: some View {
      ZStack {
        editor
          .opacity(isEditorVisible ? 1 : 0)
          .allowsHitTesting(isEditorVisible)
          .accessibilityHidden(!isEditorVisible)

        if visibleNotes.isEmpty {
          VStack(spacing: 10) {
            ContentUnavailableView(
              activeFolderID == nil ? "Unfiled is Empty" : "Folder is Empty",
              systemImage: activeFolderID == nil ? "tray" : "folder",
              description: Text("Create a note here to get started.")
            )
            Button("New note") {
              appState.addNote(inFolderID: activeFolderID)
            }
            .keyboardShortcut("t", modifiers: .command)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain)
          .accessibilityLabel(
            activeFolderID == nil ? "Unfiled is empty" : "Folder is empty"
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      .onChange(of: isEditorVisible) { _, isVisible in
        synchronizeBodyCommandGuard()
        if isVisible {
          let restoreBodyFocus = restoreEditorFocusAfterHide
          restoreEditorFocusAfterHide = false
          DispatchQueue.main.async {
            guard self.isEditorVisible,
              let textView = self.editorCommands.textView,
              let window = textView.window
            else { return }
            self.editorCommands.refreshFormattingState()
            if restoreBodyFocus {
              _ = window.makeFirstResponder(textView)
            }
          }
        } else {
          let textView = editorCommands.textView
          restoreEditorFocusAfterHide = textView?.window?.firstResponder === textView
          neutralizeHiddenEditor()
        }
      }
    }

    private func neutralizeHiddenEditor() {
      let textView = editorCommands.textView
      editorCommands.cancelFocusedDictation()
      if let window = textView?.window {
        _ = window.makeFirstResponder(nil)
      }
      editorCommands.textView = nil
    }

    private func synchronizeBodyCommandGuard() {
      editorCommands.areBodyCommandsBlocked = isBlockingOverlayPresented
        || !isEditorVisible
      editorCommands.isBodyCommandContextBlocked = editorFocus == .title
    }

    private var menuPanelResizeAppliesMargin: Bool {
      !isPinned && sizing == .storedPreferences
    }

    private var menuPanelResizePaintInsets: EdgeInsets {
      guard menuPanelResizeAppliesMargin,
        case let .inset(layout) = menuPanelResize.publishedBodyPolicy
      else { return EdgeInsets() }
      return layout.swiftUIBodyInsets
    }

    private var menuPanelBodyIsPainted: Bool {
      guard menuPanelResizeAppliesMargin else { return true }
      if case .inset = menuPanelResize.publishedBodyPolicy { return true }
      return false
    }

    private var storedPanelSize: CGSize? {
      guard sizing == .storedPreferences else { return nil }
      if let effectiveContentSize = menuPanelResize.effectiveContentSize {
        return effectiveContentSize
      }
      let preferred = preferredMenuPanelSize
      let screen = editorCommands.textView?.window?.screen
        ?? menuPanelGeometryStore?.statusLabelFrame.flatMap { statusFrame in
          NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: statusFrame.midX, y: statusFrame.midY))
          }
        }
        ?? NSScreen.main
      guard let available = screen?.visibleFrame.size,
        available.width > 0,
        available.height > 0
      else { return preferred }
      return NotesPanelSizing.storedSize(preferred: preferred, available: available)
    }

    @ViewBuilder
    private var editor: some View {
      if let note = appState.selectedNote {
        let showsFormattingBar = appState.preferences.showFormattingBar
        let fileReferences = appState.selectedNoteFileReferences
        let toolbarDirectlyAboveEditor = showsFormattingBar && isEditorVisible
          && presentedAgentBannerOccurrence == nil && fileReferences.isEmpty
        let editorTopPadding: CGFloat = solidChrome.isActive
          ? (toolbarDirectlyAboveEditor ? 4 : 12) : 10
        VStack(spacing: 0) {
          if let mode = DictationShortcutHelpMode.resolve(
            isReady: modifierShortcutPresentation.isReady,
            isCaptureActive: dictationRuntime.canCancel,
            showsGuide: appState.preferences.showDictationShortcutGuide
          ) {
            if solidChrome.isActive, mode == .recovery {
              if modifierShortcutPresentation.recoveryAction != .enableInputMonitoring
                || !dictationRuntime.isInputMonitoringNoticeDismissed
              {
                paperModifierShortcutRecovery
              }
            } else {
              DictationShortcutHelpRow(
                mode: mode,
                presentation: modifierShortcutPresentation,
                destinationCopy: dictationRuntime.destinationGuidanceCopy,
                onRecovery: performShortcutRecovery,
                onDismissGuide: {
                  appState.updatePreferences { $0.showDictationShortcutGuide = false }
                }
              )
            }
          }
          if showsFormattingBar {
            FormattingBar(
              appState: appState,
              commands: editorCommands,
              dictationRuntime: dictationRuntime,
              isPinned: isPinned,
              isEditorVisible: isEditorVisible,
              isTitleFocused: editorFocus == .title,
              windowReserve: menuPanelResizePaintInsets,
              onDelete: {
                if let note = visibleSelectedNote {
                  requestDeletion(note)
                }
              }
            )
            .transition(
              .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
              )
            )
            .animation(reduceMotion ? nil : motion.quick, value: showsFormattingBar)
          }
          if solidChrome.isActive && isEditorVisible {
            agentUpdateBanner.padding(.top, showsFormattingBar ? 12 : 0)
          }
          if !fileReferences.isEmpty {
            NoteFileReferenceView(
              references: fileReferences,
              canAdd: appState.canAddFileReference(noteID: note.id),
              onAdd: { chooseFile(for: note.id) },
              onOpen: openFileReference,
              onReveal: revealFileReference,
              onLocate: locateFileReference,
              onRemove: { referenceID in
                appState.removeFileReference(
                  referenceID: referenceID,
                  undoManager: Self.fileReferenceUndoManager(commands: editorCommands)
                )
              }
            )
          }
          NativeRichTextEditor(
            text: note.body,
            richTextRTF: note.richTextRTF,
            noteID: note.id,
            title: note.title,
            titleFontFamily: note.titleFontFamily ?? appState.preferences.fontFamily,
            isPinned: isPinned,
            onTitleChange: { title in
              guard visibleSelectedNote?.id == note.id else { return }
              appState.updateSelected(title: title)
            },
            onTitleFocusChange: { isFocused in
              if isFocused {
                editorFocus = .title
              } else if editorFocus == .title {
                editorFocus = nil
              }
              synchronizeBodyCommandGuard()
            },
            onChange: { body, richTextRTF in
              guard visibleSelectedNote?.id == note.id else { return }
              appState.updateSelected(body: body, richTextRTF: richTextRTF)
            },
            fontFamily: appState.preferences.fontFamily,
            fontSize: appState.preferences.fontSize,
            showScrollEdgeBlur: appState.preferences.showScrollEdgeBlur,
            scrollEdgeBlurAmount: appState.preferences.scrollEdgeBlurAmount,
            reduceMotion: reduceMotion,
            automaticLists: appState.preferences.automaticLists,
            commands: editorCommands,
            isVisible: isEditorVisible,
            liveNoteIDs: Set(appState.workspace.notes.map(\.id)),
            noteLinkTitles: Dictionary(
              uniqueKeysWithValues: appState.workspace.notes.map { ($0.id, $0.displayTitle) }
            ),
            inlineImageStore: appState.inlineNoteImageStore,
            onInlineImageError: appState.inlineNoteImageImportFailed,
            onRequestNoteLink: { range in
              guard !isBlockingOverlayPresented,
                let source = visibleSelectedNote,
                source.id == note.id,
                let insertionTarget = EditorNoteLinkTarget(
                  note: source,
                  range: range,
                  commands: editorCommands
                )
              else { return }
              noteLinkPickerController.present(
                sourceNoteID: source.id,
                replacementRange: range,
                sourceRevision: source.revision
              )
              guard noteLinkPickerController.isPresented else { return }
              pendingNoteLinkTarget = insertionTarget
              synchronizeBodyCommandGuard()
              guard insertionTarget.capturePickerBlock(commands: editorCommands) else {
                pendingNoteLinkTarget = nil
                noteLinkPickerController.dismiss()
                return
              }
            },
            onOpenNoteLink: openNoteLink,
            onUnavailableNoteLink: appState.reportUnavailableNoteLink
          )
          .focused($editorFocus, equals: .body)
          .background(
            EditorCommandVisibilityBoundary(
              appState: appState,
              dictationRuntime: dictationRuntime,
              commands: editorCommands,
              isVisible: isEditorVisible
            )
            .frame(width: 0, height: 0)
          )
          .background {
            EditorFindShortcutRouter(commands: editorCommands)
              .frame(width: 0, height: 0)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          .id(note.id)
          .padding(.leading, solidChrome.isActive ? 1 : 0)
          .padding(.top, editorTopPadding)
          .padding(.bottom, solidChrome.isActive ? 8 : 10)
        }
      }
    }
  }

  private struct EditorCommandVisibilityBoundary: NSViewRepresentable {
    @ObservedObject var appState: AppState
    @ObservedObject var dictationRuntime: DictationRuntime
    let commands: EditorCommands
    let isVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
      context.coordinator.isActive = true
      return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      let generation = context.coordinator.beginUpdate(isVisible: isVisible)
      guard !isVisible else { return }
      DispatchQueue.main.async {
        guard context.coordinator.isActive,
          context.coordinator.generation == generation,
          !context.coordinator.isVisible
        else { return }
        let textView = commands.textView
        commands.cancelFocusedDictation()
        if let window = textView?.window {
          _ = window.makeFirstResponder(nil)
        }
        commands.textView = nil
      }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
      coordinator.isActive = false
      coordinator.generation &+= 1
    }

    final class Coordinator {
      var isVisible = true
      var isActive = true
      var generation: UInt64 = 0

      func beginUpdate(isVisible: Bool) -> UInt64 {
        generation &+= 1
        self.isVisible = isVisible
        return generation
      }
    }
  }

  struct FolderNavigatorOverflowPresentation: Equatable {
    static let railWidth: CGFloat = 56

    let contentWidth: CGFloat
    let referenceWidth: CGFloat

    var overflows: Bool {
      contentWidth > referenceWidth
    }

    var railWidth: CGFloat {
      overflows ? Self.railWidth : 0
    }
  }

  struct FolderNavigatorOcclusionPresentation: Equatable {
    let composerLeadingX: CGFloat

    func covers(_ frame: CGRect?) -> Bool {
      guard let frame else { return true }
      return frame.maxX > composerLeadingX
    }
  }

  struct FolderNavigatorMaskPresentation: Equatable {
    static let preferredComposerWidth: CGFloat = 340
    static let preferredFadeWidth: CGFloat = 12

    let bandWidth: CGFloat

    var composerWidth: CGFloat {
      min(Self.preferredComposerWidth, max(0, bandWidth))
    }

    var leadingWidth: CGFloat {
      max(0, bandWidth - composerWidth)
    }

    var fadeWidth: CGFloat {
      min(Self.preferredFadeWidth, leadingWidth)
    }

    var opaqueWidth: CGFloat {
      leadingWidth - fadeWidth
    }

  }

  private struct FolderNavigator: View {
    private enum FocusedRow: Hashable {
      case unfiled
      case folder(UUID)
      case trash
      case newFolder
    }

    private enum NoteDropTarget: Hashable {
      case unfiled
      case folder(UUID)

      var folderID: UUID? {
        switch self {
        case .unfiled: return nil
        case .folder(let id): return id
        }
      }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.fleckUIFont) private var uiFont
    @FocusState private var focusedRow: FocusedRow?
    @FocusState private var isUnfiledDisclosureFocused: Bool
    @Binding private var draggedSource: NoteDropSource?
    @Binding private var dragSession: ReorderDropSession?
    @State private var editingFolderID: UUID?
    @State private var isCreatingFolder = false
    @State private var folderNameDraft = ""
    @State private var noteDropTarget: NoteDropTarget?
    @State private var folderReorder: ReorderInteraction?
    @State private var isUnfiledHovered = false
    @State private var unfiledInteractionSource: AppInteractionSource = .keyboard
    @State private var folderContentWidth: CGFloat = 0
    @State private var preTrashBandWidth: CGFloat = 0
    @State private var frozenOverflow: Bool?
    @State private var frozenUnfiledDisclosure: Bool?
    @State private var rowFrames: [NoteDropTarget: CGRect] = [:]
    @State private var folderCreationSource: AppInteractionSource = .keyboard
    @State private var isNewFolderTextEditing = false
    @State private var isRenamingFolderTextEditing = false
    @State private var renameFocusRequest: UInt64 = 0
    @State private var focusedRowBeforeComposition: FocusedRow?
    @State private var wasUnfiledDisclosureFocusedBeforeComposition = false
    private var solidChrome: NotesSolidChrome {
      NotesSolidChrome(theme: theme, appearance: appState.preferences.chromeAppearance)
    }

    private var folderNavigatorMaxHeight: CGFloat { solidChrome.isActive ? 28 : 32 }

    private enum FolderScrollTarget {
      case leading
      case trailing
    }

    private struct FolderContentWidthKey: PreferenceKey {
      static let defaultValue: CGFloat = 0
      static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
      }
    }

    private struct FolderBandWidthKey: PreferenceKey {
      static let defaultValue: CGFloat = 0
      static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
      }
    }

    private struct FolderRowFrameKey: PreferenceKey {
      static let defaultValue: [NoteDropTarget: CGRect] = [:]
      static func reduce(
        value: inout [NoteDropTarget: CGRect],
        nextValue: () -> [NoteDropTarget: CGRect]
      ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
      }
    }

    let menuWindowDrop: MenuWindowNoteDropCoordinator?
    let activeFolderID: UUID?
    let onSelect: (UUID?) -> Void
    let onDelete: (Folder) -> Void
    let onOpenTrash: () -> Void

    init(
      draggedSource: Binding<NoteDropSource?>,
      dragSession: Binding<ReorderDropSession?>,
      menuWindowDrop: MenuWindowNoteDropCoordinator?,
      activeFolderID: UUID?,
      onSelect: @escaping (UUID?) -> Void,
      onDelete: @escaping (Folder) -> Void,
      onOpenTrash: @escaping () -> Void
    ) {
      self._draggedSource = draggedSource
      self._dragSession = dragSession
      self.menuWindowDrop = menuWindowDrop
      self.activeFolderID = activeFolderID
      self.onSelect = onSelect
      self.onDelete = onDelete
      self.onOpenTrash = onOpenTrash
    }

    var body: some View {
      HStack(spacing: solidChrome.isActive ? 3 : 4) {
        folderNavigationLayer
          .frame(maxWidth: .infinity)
          .frame(height: folderNavigatorMaxHeight)
          .mask(alignment: .leading) {
            if isCreatingFolder {
              HStack(spacing: 0) {
                Color.white.frame(width: maskPresentation.opaqueWidth)
                LinearGradient(
                  colors: [.white, .clear],
                  startPoint: .leading,
                  endPoint: .trailing
                )
                .frame(width: maskPresentation.fadeWidth)
                Color.clear.frame(width: maskPresentation.composerWidth)
              }
            } else {
              Color.white
            }
          }
          .overlay(alignment: .trailing) {
            folderComposer
              .frame(
                width: isCreatingFolder ? maskPresentation.composerWidth : 28,
                alignment: solidChrome.isActive && !isCreatingFolder ? .trailing : .leading
              )
          }
          .background {
            GeometryReader { band in
              Color.clear.preference(key: FolderBandWidthKey.self, value: band.size.width)
            }
          }

        if solidChrome.isActive {
          Rectangle()
            .fill(solidChrome.outline)
            .frame(width: 1, height: 24)
            .accessibilityHidden(true)
        } else {
          Divider().frame(height: 20)
        }

        trashRow
          .padding(.leading, solidChrome.isActive ? 1 : 0)
      }
      .coordinateSpace(name: "folder-navigator-band")
      .onPreferenceChange(FolderContentWidthKey.self) { folderContentWidth = $0 }
      .onPreferenceChange(FolderBandWidthKey.self) { preTrashBandWidth = $0 }
      .onPreferenceChange(FolderRowFrameKey.self) { rowFrames = $0 }
      .onChange(of: isUnfiledCompact) { _, _ in
        if isCreatingFolder { frozenUnfiledDisclosure = nil }
      }
      .onChange(of: isRenamingFolderTextEditing) { wasEditing, isEditing in
        guard let editingFolderID, wasEditing, !isEditing,
          appState.workspace.folders.contains(where: { $0.id == editingFolderID })
        else { return }
        commitFolderEditing(source: currentInteractionSource, preservingFocus: true)
      }
      .animation(
        motion.allowsSpatialMotion(for: unfiledInteractionSource) ? folderMorphAnimation : nil,
        value: isUnfiledCompact
      )
      .onChange(of: draggedSource) { oldValue, newValue in
        if oldValue != newValue {
          noteDropTarget = nil
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, solidChrome.isActive ? 4 : 5)
      .padding(.bottom, solidChrome.isActive ? 3 : 5)
      .onMoveCommand { direction in
        guard !isFolderTextInputActive else { return }
        moveFocus(direction)
      }
      .onDeleteCommand {
        guard !isFolderTextInputActive else { return }
        guard case .folder(let id) = focusedRow,
          !isCovered(.folder(id)),
          let folder = appState.workspace.folders.first(where: { $0.id == id })
        else { return }
        onDelete(folder)
      }
      .onChange(of: appState.workspace.folders.map(\.id)) { _, ids in
        if let folderReorder, folderReorder.originalIDs != ids { self.folderReorder = nil }
        if let editingFolderID, !ids.contains(editingFolderID) {
          cancelFolderEditing()
        }
      }
      .onDisappear { folderReorder = nil }
      .onExitCommand {
        guard !isFolderTextInputActive else { return }
        folderReorder = nil
        cancelFolderEditing()
      }
      .onKeyPress(phases: .down) { press in
        guard !isFolderTextInputActive else { return .ignored }
        guard isF2(press), beginRename() else { return .ignored }
        return .handled
      }
      .onKeyPress(keys: [.return, .space], phases: .down) { _ in
        guard !isFolderTextInputActive else { return .ignored }
        activateFocusedRow()
        return .handled
      }
    }

    private var folderNavigationLayer: some View {
      HStack(spacing: 0) {
        rootRow
          .background(rowFrameReader(for: .unfiled))
          .padding(.trailing, 4)

        ScrollViewReader { scrollProxy in
          HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 0) {
                Color.clear
                  .frame(width: 0, height: 0)
                  .id(FolderScrollTarget.leading)
                HStack(spacing: 3) {
                  ForEach(appState.workspace.folders, id: \.id) { folder in
                    folderRow(folder)
                      .background(rowFrameReader(for: .folder(folder.id)))
                  }
                }
                .background {
                  GeometryReader { content in
                    Color.clear.preference(
                      key: FolderContentWidthKey.self,
                      value: content.size.width
                    )
                  }
                }
                .background(ReorderDragLifecycle(active: folderReorder != nil,
                  hasTarget: folderReorder?.targetID != nil
                    && folderReorder?.originalIDs == appState.workspace.folders.map(\.id),
                  cancel: { folderReorder = nil }))
                Color.clear
                  .frame(width: 0, height: 0)
                  .id(FolderScrollTarget.trailing)
              }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: folderNavigatorMaxHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folders")

            Group {
              if showsOverflowRail {
                overflowControls(scrollProxy: scrollProxy)
                  .opacity(isCreatingFolder ? 0 : 1)
                  .disabled(isCreatingFolder)
                  .allowsHitTesting(!isCreatingFolder)
                  .accessibilityHidden(isCreatingFolder)
              }
            }
            .frame(width: reservedRailWidth)
          }
          .onChange(of: showsOverflowRail) { wasOverflowing, isOverflowing in
            if wasOverflowing && !isOverflowing {
              scrollProxy.scrollTo(FolderScrollTarget.leading, anchor: .leading)
            }
          }
        }
        .frame(maxWidth: .infinity)

        Color.clear.frame(width: 28, height: 28)
      }
    }

    private func overflowControls(scrollProxy: ScrollViewProxy) -> some View {
      HStack(spacing: 0) {
        Button {
          guard !isCreatingFolder else { return }
          scrollProxy.scrollTo(FolderScrollTarget.leading, anchor: .leading)
        } label: {
          Image(systemName: "chevron.left")
            .font(.caption)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Reveal earlier folders")
        .help("Show earlier folders")

        Button {
          guard !isCreatingFolder else { return }
          scrollProxy.scrollTo(FolderScrollTarget.trailing, anchor: .trailing)
        } label: {
          Image(systemName: "chevron.right")
            .font(.caption)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Reveal later folders")
        .help("Show later folders")
      }
    }

    @ViewBuilder
    private var folderComposer: some View {
      HStack(spacing: 5) {
        Button {
          beginNewFolder(source: currentInteractionSource)
        } label: {
          Group {
            if solidChrome.isActive {
              NotesPaperIcon(glyph: .newFolder)
            } else {
              Image(systemName: "folder.badge.plus")
            }
          }
          .frame(width: solidChrome.isActive ? 26 : 28, height: solidChrome.isActive ? 26 : 28)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("New folder")
        .accessibilityIdentifier("folder-new")

        if isCreatingFolder {
          HStack(spacing: 5) {
            NativeFolderNameField(
              text: $folderNameDraft,
              isEditing: $isNewFolderTextEditing,
              onSubmit: { commitFolderEditing(source: .keyboard) },
              onCancel: { cancelFolderEditing(source: .keyboard) }
            )
              .overlay(alignment: .bottom) {
                Rectangle().fill(.secondary.opacity(0.7)).frame(height: 1)
              }

            Button {
              commitFolderEditing(source: currentInteractionSource)
            } label: {
              Image(systemName: "checkmark")
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
            .disabled(trimmedFolderName.isEmpty)
            .accessibilityLabel("Create folder")

            Button {
              cancelFolderEditing(source: currentInteractionSource)
            } label: {
              Image(systemName: "xmark")
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Cancel new folder")
          }
          .transition(composerTransition)
        }
      }
    }

    private struct NativeFolderNameField: NSViewRepresentable {
      @Binding var text: String
      @Binding var isEditing: Bool
      var placeholder = "New folder"
      var accessibilityIdentifier = "folder-new-name"
      var focusRequest: UInt64 = 0
      let onSubmit: () -> Void
      let onCancel: () -> Void

      func makeCoordinator() -> Coordinator {
        Coordinator(
          text: $text,
          isEditing: $isEditing,
          onSubmit: onSubmit,
          onCancel: onCancel
        )
      }

      func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView field: OwnershipReportingTextField,
        context: Context
      ) -> CGSize? {
        let font = field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let currentText = (field.currentEditor() as? NSTextView)?.string ?? text
        let textCell = NSTextFieldCell(textCell: currentText)
        let placeholderCell = NSTextFieldCell(textCell: placeholder)
        for cell in [textCell, placeholderCell] {
          cell.font = font
          cell.isBezeled = field.isBezeled
          cell.isBordered = field.isBordered
          cell.drawsBackground = field.drawsBackground
          cell.controlSize = field.cell?.controlSize ?? .regular
        }
        let textWidth = (currentText as NSString).size(withAttributes: [.font: font]).width
        let placeholderTextWidth = (placeholder as NSString)
          .size(withAttributes: [.font: font]).width
        let caretRoom: CGFloat = 2
        let idealWidth = max(
          max(textWidth, textCell.cellSize.width),
          max(placeholderTextWidth, placeholderCell.cellSize.width)
        ) + caretRoom
        let idealHeight = max(textCell.cellSize.height, placeholderCell.cellSize.height)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        return CGSize(width: width, height: idealHeight)
      }

      func makeNSView(context: Context) -> OwnershipReportingTextField {
        let field = OwnershipReportingTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.delegate = context.coordinator
        field.onOwnershipChange = { [weak coordinator = context.coordinator] ownsEditor in
          coordinator?.setEditingOwnership(ownsEditor)
        }
        context.coordinator.requestFocus(for: field)
        return field
      }

      func updateNSView(_ field: OwnershipReportingTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEditing = $isEditing
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if context.coordinator.focusRequest != focusRequest {
          context.coordinator.focusRequest = focusRequest
          context.coordinator.hasFocused = false
        }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
          field.stringValue != text
        {
          field.stringValue = text
        }
        context.coordinator.requestFocus(for: field)
      }

      static func dismantleNSView(
        _ field: OwnershipReportingTextField,
        coordinator: Coordinator
      ) {
        coordinator.isActive = false
        coordinator.focusGeneration &+= 1
        field.onOwnershipChange = nil
        field.isHidden = true
      }

      @MainActor
      final class OwnershipReportingTextField: NSTextField {
        var onOwnershipChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
          let becameFirstResponder = super.becomeFirstResponder()
          if becameFirstResponder { reportOwnershipAfterResponderTransition() }
          return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
          let resignedFirstResponder = super.resignFirstResponder()
          if resignedFirstResponder { reportOwnershipAfterResponderTransition() }
          return resignedFirstResponder
        }

        func reportOwnershipAfterResponderTransition() {
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let editor = currentEditor()
            onOwnershipChange?(editor != nil && window?.firstResponder === editor)
          }
        }
      }

      @MainActor
      final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isEditing: Binding<Bool>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        var isActive = true
        var hasFocused = false
        var focusRequest: UInt64 = 0
        var focusGeneration: UInt64 = 0

        init(
          text: Binding<String>,
          isEditing: Binding<Bool>,
          onSubmit: @escaping () -> Void,
          onCancel: @escaping () -> Void
        ) {
          self.text = text
          self.isEditing = isEditing
          self.onSubmit = onSubmit
          self.onCancel = onCancel
        }

        func requestFocus(for field: OwnershipReportingTextField) {
          guard !hasFocused else { return }
          focusGeneration &+= 1
          let generation = focusGeneration
          DispatchQueue.main.async {
            guard self.isActive, self.focusGeneration == generation, field.window != nil else { return }
            self.hasFocused = field.window?.makeFirstResponder(field) == true
            field.reportOwnershipAfterResponderTransition()
          }
        }

        func controlTextDidChange(_ notification: Notification) {
          guard let field = notification.object as? NSTextField else { return }
          text.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
          setEditingOwnership(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
          setEditingOwnership(false)
        }

        func setEditingOwnership(_ ownsEditor: Bool) {
          guard isActive, isEditing.wrappedValue != ownsEditor else { return }
          isEditing.wrappedValue = ownsEditor
        }

        func control(
          _ control: NSControl,
          textView: NSTextView,
          doCommandBy commandSelector: Selector
        ) -> Bool {
          switch commandSelector {
          case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
            onSubmit()
            return true
          case #selector(NSResponder.cancelOperation(_:)):
            guard !textView.hasMarkedText() else { return false }
            onCancel()
            return true
          default:
            return false
          }
        }
      }
    }

    private var trashRow: some View {
      Button {
        onOpenTrash()
      } label: {
        rowLabel(
          name: "Trash",
          systemImage: "trash",
          paperGlyph: .folderTrash,
          count: appState.trashedNotes.count,
          isSelected: false,
          isEmpty: appState.trashedNotes.isEmpty,
          isFocused: solidChrome.isActive && focusedRow == .trash
        )
        .frame(minHeight: 28)
        .contentShape(RoundedRectangle(cornerRadius: 6))
      }
      .fixedSize(horizontal: true, vertical: false)
      .buttonStyle(.plain)
      .fleckHoverFill(in: RoundedRectangle(cornerRadius: 6))
      .focused($focusedRow, equals: .trash)
      .focusable()
      .accessibilityLabel("Trash")
      .accessibilityIdentifier("folder-trash")
      .accessibilityValue(
        appState.trashedNotes.isEmpty
          ? "Empty"
          : "\(appState.trashedNotes.count) notes"
      )
    }

    private var rootRow: some View {
      let unfiledNotes = appState.visibleNotes(in: nil)
      let isDisclosurePainted = frozenUnfiledDisclosure ?? showsUnfiledDisclosure
      return HStack(spacing: 0) {
        Button {
          focusedRow = .unfiled
          onSelect(nil)
        } label: {
          rowLabel(
            name: "Unfiled",
            systemImage: "tray",
            paperGlyph: .inbox,
            count: unfiledNotes.count,
            isSelected: activeFolderID == nil,
            isEmpty: unfiledNotes.isEmpty,
            isDropTarget: isNoteDropTarget(.unfiled),
            isFocused: focusedRow == .unfiled,
            showsName: !isUnfiledCompact,
            revealsName: true
          )
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused($focusedRow, equals: .unfiled)
        .focusEffectDisabled()
        .accessibilityLabel("Unfiled")
        .accessibilityIdentifier("folder-unfiled")
        .accessibilityValue(unfiledAccessibilityValue)
        .accessibilityAddTraits(activeFolderID == nil ? .isSelected : [])
        .accessibilityAction(named: Text("Toggle Unfiled compact mode")) {
          setUnfiledCompact(!isUnfiledCompact)
        }

        Button {
          let isPointer = NSApp.currentEvent.map {
            [.leftMouseDown, .leftMouseUp].contains($0.type)
          } ?? false
          setUnfiledCompact(!isUnfiledCompact, source: isPointer ? .pointer : .keyboard)
        } label: {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isUnfiledCompact ? 0 : 180))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel(
          isUnfiledCompact ? "Expand Unfiled" : "Collapse Unfiled"
        )
        .focusable()
        .focused($isUnfiledDisclosureFocused)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
          setUnfiledCompact(!isUnfiledCompact)
          return .handled
        }
        .opacity(isDisclosurePainted ? 1 : 0)
        .frame(width: isDisclosurePainted ? 28 : 0, alignment: .leading)
        .clipped()
        .allowsHitTesting(isDisclosurePainted)
        .accessibilityHidden(!isDisclosurePainted)
      }
      .fixedSize(horizontal: true, vertical: false)
      .animation(folderMorphAnimation, value: isDisclosurePainted)
      .onHover { isUnfiledHovered = $0 }
      .contentShape(Rectangle())
      .background(nativeNoteDropAnchor(.unfiled))
      .onDrop(
        of: [FolderDragPayload.noteType],
        delegate: noteDropDelegate(.unfiled)
      )
      .disabled(isCovered(.unfiled))
      .allowsHitTesting(!isCovered(.unfiled))
      .accessibilityHidden(isCovered(.unfiled))
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
      if editingFolderID == folder.id {
        folderEditor(
          label: "Folder name",
          accessibilityIdentifier: "folder-rename-\(folder.id.uuidString)"
        )
      } else {
        Button {
          focusedRow = .folder(folder.id)
          onSelect(folder.id)
        } label: {
          rowLabel(
            name: folder.name,
            systemImage: "folder",
            paperGlyph: .folder,
            count: appState.visibleNotes(in: folder.id).count,
            isSelected: activeFolderID == folder.id,
            isEmpty: appState.visibleNotes(in: folder.id).isEmpty,
            isDropTarget: isNoteDropTarget(.folder(folder.id)),
            isFocused: focusedRow == .folder(folder.id)
          )
        }
        .buttonStyle(.plain)
        .fleckHoverFill(in: RoundedRectangle(cornerRadius: 6))
        .background(nativeNoteDropAnchor(.folder(folder.id)))
        .modifier(ReorderDropTarget(
          destinationID: folder.id, type: FolderDragPayload.folderType,
          interaction: $folderReorder,
          session: $dragSession,
          currentIDs: { appState.workspace.folders.map(\.id) },
          currentPinnedIDs: { [] },
          accepts: { !isCovered(.folder(folder.id)) },
          finish: {},
          move: { id, destination in try? appState.reorderFolder(id: id, to: destination) },
          noteDrop: noteDropDelegate(.folder(folder.id))
        ))
        .modifier(ReorderDragSource(begin: {
          let interaction = ReorderInteraction(sourceID: folder.id,
            originalIDs: appState.workspace.folders.map(\.id))
          let session = ReorderDropSession(folder:
            .init(folderID: folder.id, sessionID: interaction.sessionID))
          dragSession?.cancel()
          dragSession = session
          folderReorder = interaction
          return (FolderDragPayload.folderProvider(folderID: folder.id, sessionID: interaction.sessionID), nil, { operation in
            session.end(operation: operation)
            guard folderReorder?.sessionID == interaction.sessionID else { return }
            folderReorder = nil
          })
        }))
        .focusable()
        .focused($focusedRow, equals: .folder(folder.id))
        .focusEffectDisabled()
        .contextMenu {
          Button("Move Left", systemImage: "arrow.left") { moveFolder(folder.id, offset: -1) }
          Button("Move Right", systemImage: "arrow.right") { moveFolder(folder.id, offset: 1) }
          Button("Rename", systemImage: "pencil") {
            _ = beginRename(folderID: folder.id)
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            onDelete(folder)
          }
        }
        .accessibilityLabel(folder.name)
        .accessibilityIdentifier("folder-\(folder.id.uuidString)")
        .accessibilityValue(
          "\(appState.visibleNotes(in: folder.id).count) notes"
            + (activeFolderID == folder.id ? ", Selected" : "")
            + (appState.visibleNotes(in: folder.id).isEmpty ? ", Empty" : "")
            + (isNoteDropTarget(.folder(folder.id)) ? ", Drop target" : "")
        )
        .accessibilityAddTraits(activeFolderID == folder.id ? .isSelected : [])
        .disabled(isCovered(.folder(folder.id)))
        .allowsHitTesting(!isCovered(.folder(folder.id)))
        .accessibilityHidden(isCovered(.folder(folder.id)))
      }
    }

    @ViewBuilder
    private func folderEditor(
      label: String,
      accessibilityIdentifier: String
    ) -> some View {
      NativeFolderNameField(
        text: $folderNameDraft,
        isEditing: $isRenamingFolderTextEditing,
        placeholder: label,
        accessibilityIdentifier: accessibilityIdentifier,
        focusRequest: renameFocusRequest,
        onSubmit: { commitFolderEditing() },
        onCancel: { cancelFolderEditing() }
      )
      .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func rowLabel(
      name: String,
      systemImage: String,
      paperGlyph: NotesPaperIcon.Glyph,
      count: Int,
      isSelected: Bool,
      isEmpty: Bool,
      isDropTarget: Bool = false,
      isFocused: Bool = false,
      showsName: Bool = true,
      revealsName: Bool = false
    ) -> some View {
      let isSolidTrash = solidChrome.isActive && paperGlyph == .folderTrash
      HStack(spacing: 7) {
        if solidChrome.isActive {
          NotesPaperIcon(glyph: paperGlyph)
        } else {
          Image(systemName: systemImage)
            .frame(width: 18)
        }
        if revealsName {
          if showsName || !solidChrome.isActive {
            HStack(spacing: 0) {
              Text(name)
                .lineLimit(1)
                .fixedSize()
                .opacity(showsName ? 1 : 0)
                .frame(width: showsName ? nil : 0, alignment: .leading)
                .clipped()
                .padding(.trailing, showsName ? 7 : 0)
              Spacer(minLength: showsName ? 4 : 2)
            }
          }
        } else {
          Text(name)
            .lineLimit(1)
            .padding(.trailing, isSolidTrash ? 10 : 0)
          if !solidChrome.isActive { Spacer(minLength: 4) }
        }
        Text(count, format: .number)
          .font(uiFont.font(.caption).monospacedDigit())
          .foregroundStyle(theme.color(.caption))
      }
      .padding(.leading, isSolidTrash ? 7 : 8)
      .padding(.trailing, 8)
      .padding(.vertical, solidChrome.isActive ? 0 : 5)
      .frame(minHeight: solidChrome.isActive ? 27 : 24)
      .background(
        isDropTarget
          ? theme.color(.hoverFill)
          : (isSelected ? theme.color(.selectionFill) : .clear),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .foregroundStyle(isSelected ? theme.color(.selectionText) : theme.color(.textPrimary))
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .fleckNeutralControlOutline(
        isFocused: isFocused && (solidChrome.isActive || !isSelected),
        cornerRadius: 6
      )
      .accessibilityHint(isEmpty ? "Empty folder" : "")
    }

    private func noteDropDelegate(_ target: NoteDropTarget) -> NoteDropDelegate {
      NoteDropDelegate(
        target: target,
        draggedSource: $draggedSource,
        dropTarget: $noteDropTarget,
        canAccept: { expectedSource, targetFolderID in
          canHighlightNoteDrop(
            expectedSource: expectedSource,
            targetFolderID: targetFolderID
          )
        },
        perform: { providers, targetFolderID, expectedSource in
          handleNoteDrop(
            providers,
            targetFolderID: targetFolderID,
            expectedSource: expectedSource
          )
        }
      )
    }

    @ViewBuilder
    private func nativeNoteDropAnchor(_ target: NoteDropTarget) -> some View {
      if let menuWindowDrop {
        MenuWindowFolderDropAnchor(
          coordinator: menuWindowDrop,
          canAccept: { data in
            guard let source = FolderDragPayload.noteValue(from: data) else { return false }
            return canHighlightNoteDrop(
              expectedSource: source,
              targetFolderID: target.folderID
            )
          },
          perform: { data in
            guard let source = FolderDragPayload.noteValue(from: data) else { return false }
            return handleNoteDrop(
              data,
              targetFolderID: target.folderID,
              expectedSource: source
            )
          },
          setHovered: { hovered in
            if hovered && !isCovered(target) {
              noteDropTarget = target
            } else if noteDropTarget == target {
              noteDropTarget = nil
            }
          }
        )
      }
    }

    private func isNoteDropTarget(_ target: NoteDropTarget) -> Bool {
      guard let draggedSource else { return false }
      return noteDropTarget == target
        && canHighlightNoteDrop(
          expectedSource: draggedSource,
          targetFolderID: target.folderID
        )
    }

    private func canHighlightNoteDrop(
      expectedSource: NoteDropSource,
      targetFolderID: UUID?
    ) -> Bool {
      let target = targetFolderID.map(NoteDropTarget.folder) ?? .unfiled
      guard !isCovered(target) else { return false }
      guard draggedSource == expectedSource, dragSession?.id == expectedSource.dragSessionID,
        dragSession?.canAcceptDrop == true else { return false }
      return NoteDropPresentation.isValidTarget(
        draggedSource: expectedSource,
        targetFolderID: targetFolderID,
        notes: appState.workspace.notes,
        validTargetFolderIDs: Set(appState.workspace.folders.map(\.id))
      )
    }

    private var isUnfiledCompact: Bool {
      appState.preferences.isUnfiledCompact
    }

    private var unfiledAccessibilityValue: String {
      let notes = appState.visibleNotes(in: nil)
      var parts = ["\(notes.count) notes"]
      if activeFolderID == nil { parts.append("Selected") }
      if notes.isEmpty { parts.append("Empty") }
      if isUnfiledCompact { parts.append("Compact") }
      if isNoteDropTarget(.unfiled) { parts.append("Drop target") }
      return parts.joined(separator: ", ")
    }

    /// The chevron is painted only while the Unfiled row is under attention —
    /// the pointer is over it, or keyboard focus sits on the row or the chevron.
    /// Its 28pt slot belongs to the chevron: an unpainted slot takes no width, so
    /// the folder chips beside it close the gap instead of leaving dead space, and
    /// the reflow animates so it reads as deliberate rather than a jolt. A name
    /// edit freezes the painted state through `frozenUnfiledDisclosure` so the
    /// chevron does not blink out mid-typing.
    private var showsUnfiledDisclosure: Bool {
      isUnfiledHovered || focusedRow == .unfiled || isUnfiledDisclosureFocused
    }

    private func setUnfiledCompact(
      _ compact: Bool,
      source: AppInteractionSource = .keyboard
    ) {
      unfiledInteractionSource = source
      appState.updatePreferences { $0.isUnfiledCompact = compact }
    }

    private var motion: AppMotion {
      AppMotion(reduceMotion: reduceMotion)
    }

    private var overflowPresentation: FolderNavigatorOverflowPresentation {
      FolderNavigatorOverflowPresentation(
        contentWidth: folderContentWidth,
        referenceWidth: max(preTrashBandWidth - (rowFrames[.unfiled]?.width ?? 0) - 32, 0)
      )
    }

    private var showsOverflowRail: Bool {
      frozenOverflow ?? overflowPresentation.overflows
    }

    private var reservedRailWidth: CGFloat {
      showsOverflowRail ? FolderNavigatorOverflowPresentation.railWidth : 0
    }

    private var trimmedFolderName: String {
      folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var maskPresentation: FolderNavigatorMaskPresentation {
      FolderNavigatorMaskPresentation(bandWidth: preTrashBandWidth)
    }

    private var composerLeadingX: CGFloat {
      maskPresentation.leadingWidth
    }

    private var isFolderTextInputActive: Bool {
      if isCreatingFolder { return isNewFolderTextEditing }
      guard editingFolderID != nil else { return false }
      return isRenamingFolderTextEditing
    }

    private var currentInteractionSource: AppInteractionSource {
      guard let event = NSApp.currentEvent,
        [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type)
      else { return .keyboard }
      return .pointer
    }

    private var composerTransition: AnyTransition {
      guard folderCreationSource == .pointer else { return .identity }
      if reduceMotion { return .opacity.animation(motion.state) }
      return .opacity.combined(with: .offset(x: motion.offset))
    }

    private func folderCreationAnimation(for source: AppInteractionSource) -> Animation? {
      switch source {
      case .keyboard:
        return nil
      case .pointer:
        return reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)
      case .programmatic:
        return reduceMotion ? nil : motion.state
      }
    }

    private var folderMorphAnimation: Animation? {
      reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)
    }

    private func beginNewFolder(source: AppInteractionSource) {
      guard !isCreatingFolder else { return }
      editingFolderID = nil
      isRenamingFolderTextEditing = false
      folderNameDraft = ""
      folderCreationSource = source
      frozenOverflow = overflowPresentation.overflows
      frozenUnfiledDisclosure = showsUnfiledDisclosure
      focusedRowBeforeComposition = focusedRow
      wasUnfiledDisclosureFocusedBeforeComposition = isUnfiledDisclosureFocused
      noteDropTarget = nil
      folderReorder = nil
      withAnimation(folderCreationAnimation(for: source)) {
        isCreatingFolder = true
        focusedRow = .newFolder
      }
    }

    private func beginRename(folderID: UUID? = nil) -> Bool {
      let id: UUID?
      if let folderID {
        id = folderID
      } else if case .folder(let focusedID) = focusedRow {
        id = focusedID
      } else {
        id = nil
      }
      guard let id,
        !isCovered(.folder(id)),
        let folder = appState.workspace.folders.first(where: { $0.id == id })
      else { return false }
      isCreatingFolder = false
      isNewFolderTextEditing = false
      frozenOverflow = nil
      frozenUnfiledDisclosure = nil
      focusedRowBeforeComposition = nil
      wasUnfiledDisclosureFocusedBeforeComposition = false
      isRenamingFolderTextEditing = false
      editingFolderID = id
      folderNameDraft = folder.name
      return true
    }

    private func commitFolderEditing(
      source: AppInteractionSource = .keyboard,
      preservingFocus: Bool = false
    ) {
      guard !trimmedFolderName.isEmpty else {
        if preservingFocus, editingFolderID != nil {
          focusedRow = nil
          renameFocusRequest &+= 1
        }
        return
      }
      do {
        var actionFolderID: UUID?
        if isCreatingFolder {
          _ = try appState.createFolder(named: folderNameDraft)
        } else if let editingFolderID {
          try appState.renameFolder(id: editingFolderID, name: folderNameDraft)
          actionFolderID = editingFolderID
        }
        appState.folderActionSucceeded(folderID: actionFolderID)
        if preservingFocus {
          editingFolderID = nil
          isRenamingFolderTextEditing = false
          folderNameDraft = ""
        } else {
          cancelFolderEditing(source: source)
        }
      } catch {
        appState.folderActionFailed(
          "Could not update folder: \(String(describing: error))",
          folderID: isCreatingFolder ? nil : editingFolderID
        )
        if preservingFocus, editingFolderID != nil {
          focusedRow = nil
          renameFocusRequest &+= 1
        }
      }
    }

    private func cancelFolderEditing(source: AppInteractionSource = .keyboard) {
      editingFolderID = nil
      isRenamingFolderTextEditing = false
      guard isCreatingFolder else {
        folderNameDraft = ""
        focusedRow = nil
        return
      }
      folderCreationSource = source
      isNewFolderTextEditing = false
      var transaction = Transaction(animation: folderCreationAnimation(for: source))
      transaction.disablesAnimations = source == .keyboard
      transaction.addAnimationCompletion(criteria: .logicallyComplete) {
        guard !isCreatingFolder else { return }
        frozenOverflow = nil
        frozenUnfiledDisclosure = nil
        focusedRowBeforeComposition = nil
        wasUnfiledDisclosureFocusedBeforeComposition = false
      }
      withTransaction(transaction) {
        isCreatingFolder = false
        folderNameDraft = ""
        focusedRow = focusedRowBeforeComposition
        isUnfiledDisclosureFocused = wasUnfiledDisclosureFocusedBeforeComposition
      }
    }

    private func rowFrameReader(for target: NoteDropTarget) -> some View {
      GeometryReader { row in
        Color.clear.preference(
          key: FolderRowFrameKey.self,
          value: [target: row.frame(in: .named("folder-navigator-band"))]
        )
      }
    }

    private func isCovered(_ target: NoteDropTarget) -> Bool {
      guard isCreatingFolder else { return false }
      return FolderNavigatorOcclusionPresentation(composerLeadingX: composerLeadingX)
        .covers(rowFrames[target])
    }

    private func activateFocusedRow() {
      switch focusedRow {
      case .unfiled:
        guard !isCovered(.unfiled) else { return }
        onSelect(nil)
      case .folder(let id):
        guard !isCovered(.folder(id)) else { return }
        onSelect(id)
      case .trash:
        onOpenTrash()
      case .newFolder, nil:
        break
      }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
      let rows: [FocusedRow] = ([FocusedRow.unfiled]
        + appState.workspace.folders.map { .folder($0.id) })
        .filter {
          switch $0 {
          case .unfiled: !isCovered(.unfiled)
          case .folder(let id): !isCovered(.folder(id))
          case .trash, .newFolder: true
          }
        } + [.trash]
      guard !rows.isEmpty else { return }
      let currentIndex = focusedRow.flatMap { rows.firstIndex(of: $0) } ?? 0
      focusedRow = rows[
        FolderNavigatorFocus.nextIndex(
          currentIndex: currentIndex,
          direction: direction,
          count: rows.count
        )
      ]
    }

    private func isF2(_ press: KeyPress) -> Bool {
      press.characters.unicodeScalars.contains { $0.value == UInt32(NSF2FunctionKey) }
    }

    private func handleNoteDrop(
      _ providers: [NSItemProvider],
      targetFolderID: UUID?,
      expectedSource: NoteDropSource
    ) -> Bool {
      noteDropTarget = nil
      let target = targetFolderID.map(NoteDropTarget.folder) ?? .unfiled
      guard !isCovered(target) else { return false }
      defer { if draggedSource == expectedSource { draggedSource = nil } }
      guard draggedSource == expectedSource, let dragSession,
        dragSession.id == expectedSource.dragSessionID
      else { return false }
      let capturedScope = activeFolderID
      return dragSession.acceptNoteTransfer(from: providers, source: expectedSource,
        targetFolderID: targetFolderID,
        currentSourceNotes: { appState.visibleNotes(in: expectedSource.sourceFolderID) },
        validTargetFolderIDs: { Set(appState.workspace.folders.map(\.id)) }
      ) { source, target in
        appState.moveNote(source.noteID, fromFolderID: source.sourceFolderID,
          toFolderID: target, activeFolderID: capturedScope)
      } != nil
    }

    private func handleNoteDrop(
      _ data: Data,
      targetFolderID: UUID?,
      expectedSource: NoteDropSource
    ) -> Bool {
      noteDropTarget = nil
      let target = targetFolderID.map(NoteDropTarget.folder) ?? .unfiled
      guard !isCovered(target) else { return false }
      defer { if draggedSource == expectedSource { draggedSource = nil } }
      guard draggedSource == expectedSource, let dragSession,
        dragSession.id == expectedSource.dragSessionID
      else { return false }
      let capturedScope = activeFolderID
      return dragSession.acceptNoteTransfer(data: data, source: expectedSource,
        targetFolderID: targetFolderID,
        currentSourceNotes: { appState.visibleNotes(in: expectedSource.sourceFolderID) },
        validTargetFolderIDs: { Set(appState.workspace.folders.map(\.id)) }
      ) { source, target in
        appState.moveNote(source.noteID, fromFolderID: source.sourceFolderID,
          toFolderID: target, activeFolderID: capturedScope)
      }
    }

    private struct NoteDropDelegate: DropDelegate {
      let target: NoteDropTarget
      @Binding var draggedSource: NoteDropSource?
      @Binding var dropTarget: NoteDropTarget?
      let canAccept: (NoteDropSource, UUID?) -> Bool
      let perform: ([NSItemProvider], UUID?, NoteDropSource) -> Bool

      private func matchingSource(_ info: DropInfo) -> NoteDropSource? {
        guard let expectedSource = draggedSource,
          info.hasItemsConforming(to: [FolderDragPayload.noteType]),
          canAccept(expectedSource, target.folderID)
        else { return nil }
        return expectedSource
      }

      func validateDrop(info: DropInfo) -> Bool {
        matchingSource(info) != nil
      }

      func dropEntered(info: DropInfo) {
        if matchingSource(info) != nil {
          dropTarget = target
        } else if dropTarget == target {
          dropTarget = nil
        }
      }

      func dropUpdated(info: DropInfo) -> DropProposal? {
        guard matchingSource(info) != nil else { return nil }
        return DropProposal(operation: .move)
      }

      func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
      }

      func performDrop(info: DropInfo) -> Bool {
        guard let expectedSource = matchingSource(info)
        else {
          if dropTarget == target { dropTarget = nil }
          return false
        }
        guard canAccept(expectedSource, target.folderID) else {
          if draggedSource == expectedSource { draggedSource = nil }
          if dropTarget == target { dropTarget = nil }
          return false
        }
        dropTarget = nil
        let accepted = perform(
          info.itemProviders(for: [FolderDragPayload.noteType]),
          target.folderID,
          expectedSource
        )
        if !accepted && draggedSource == expectedSource { draggedSource = nil }
        return accepted
      }
    }

    private func moveFolder(_ id: UUID, offset: Int) {
      guard let index = appState.workspace.folders.firstIndex(where: { $0.id == id }) else { return }
      try? appState.reorderFolder(id: id,
        to: min(max(index + offset, 0), appState.workspace.folders.count - 1))
    }

  }

  struct TrashPanelOverlay: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.fleckChromeAppearance) private var appearance
    let onDone: () -> Void
    var now: () -> Date = { Date() }

    var body: some View {
      let solidChrome = NotesSolidChrome(theme: theme, appearance: appearance)
      ZStack {
        Color.black.opacity(0.28)
          .ignoresSafeArea()
          .accessibilityHidden(true)

        TrashView(onDone: onDone, now: now)
          .frame(maxWidth: 520, maxHeight: solidChrome.isActive ? 360 : 400)
          .background {
            if solidChrome.isActive {
              solidChrome.dialogSurface
            }
          }
          .modifier(TrashLegacySurface(enabled: !solidChrome.isActive))
          .clipShape(RoundedRectangle(cornerRadius: 14))
          .overlay {
            if solidChrome.isActive {
              RoundedRectangle(cornerRadius: 14)
                .strokeBorder(solidChrome.outline, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
          }
          .shadow(radius: 20, y: 8)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Trash")
          .padding(8)

        Button("Close Trash", action: onDone)
          .keyboardShortcut(.cancelAction)
          .frame(width: 0, height: 0)
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
  }

  private struct TrashLegacySurface: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
      if enabled {
        content.fleckThemedSurface(cornerRadius: 14)
      } else {
        content
      }
    }
  }

  private struct NotesSolidWindowOutline: ViewModifier {
    let outline: Color?

    func body(content: Content) -> some View {
      if let outline {
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        content
          .clipShape(shape)
          .overlay {
            shape.strokeBorder(outline, lineWidth: 1)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
      } else {
        content
      }
    }
  }

  struct FolderDeleteConfirmationOverlay: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    let folder: Folder
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
      ZStack {
        Color.black.opacity(0.28)
          .ignoresSafeArea()
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Delete \(folder.name)?")
              .fleckUIFont(.headline)
            Text("Notes in this folder move to Unfiled. No notes are deleted.")
              .fleckUIFont(.callout)
              .foregroundStyle(theme.color(.textSecondary))
          }

          HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
              .keyboardShortcut(.cancelAction)
            Button("Delete Folder", role: .destructive, action: onConfirm)
              .keyboardShortcut(.defaultAction)
          }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .fleckThemedSurface(cornerRadius: 14)
        .shadow(radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete folder confirmation")
      }
    }
  }

  private struct DeleteConfirmationOverlay: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    let note: Note
    @Binding var dontAskAgain: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
      ZStack {
        Color.black.opacity(0.28)
          .ignoresSafeArea()

        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Move “\(note.displayTitle)” to Trash?")
              .fleckUIFont(.headline)
            Text("This note can be restored from Trash for 30 days.")
              .fleckUIFont(.callout)
              .foregroundStyle(theme.color(.textSecondary))
          }

          Toggle("Don't ask me again", isOn: $dontAskAgain)
            .toggleStyle(.checkbox)

          HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
              .keyboardShortcut(.cancelAction)
            Button("Confirm", role: .destructive, action: onConfirm)
              .keyboardShortcut(.defaultAction)
          }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .fleckThemedSurface(cornerRadius: 14)
        .shadow(radius: 20, y: 8)
      }
    }
  }

  func routeFontFamilyAction(
    family: String,
    isTitleFocused: Bool,
    titleMutation: (String) -> Void,
    bodyMutation: (String) -> Void
  ) {
    if isTitleFocused {
      titleMutation(family)
    } else {
      bodyMutation(family)
    }
  }

  struct DictationShortcutHelpRow: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    static let smartCaptureHelp =
      "Say a specific note title to help Fleck choose. "
      + "If it cannot find a clear match, it saves to Inbox."

    let mode: DictationShortcutHelpMode
    let presentation: DictationModifierSettingsPresentation
    let destinationCopy: String
    let onRecovery: () -> Void
    let onDismissGuide: () -> Void
    @State private var showsSmartCaptureHelp = false

    var body: some View {
      HStack(spacing: 8) {
        Image(systemName: presentation.recoveryAction == nil
          ? "keyboard"
          : "keyboard.badge.ellipsis")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(presentation.statusCopy)
            .fleckUIFont(.caption)
            .foregroundStyle(theme.color(.caption))
          if let detail = presentation.detailCopy {
            Text(detail)
              .fleckUIFont(.caption2)
              .foregroundStyle(theme.color(.caption))
          }
          if mode != .recovery {
            HStack(spacing: 4) {
              Text(destinationCopy)
              Button {
                showsSmartCaptureHelp.toggle()
              } label: {
                Image(systemName: "questionmark.circle")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("About Smart Capture")
              .popover(isPresented: $showsSmartCaptureHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                  Text("Smart Capture")
                    .fleckUIFont(.headline)
                  Text(Self.smartCaptureHelp)
                  Text("Example: “Travel plans.”")
                    .foregroundStyle(theme.color(.textSecondary))
                }
                .fleckUIFont(.callout)
                .frame(width: 280, alignment: .leading)
                .padding(12)
              }
            }
            .fleckUIFont(.caption2)
            .foregroundStyle(theme.color(.caption))
          }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 8)
        if mode.canDismissGuide {
          Button(action: onDismissGuide) {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .help("Dismiss shortcut guide")
          .accessibilityLabel("Dismiss shortcut guide")
        } else if mode == .recovery, let title = presentation.recoveryButtonTitle {
          Button(title, action: onRecovery)
            .accessibilityLabel(title)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.35))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(presentation.capsuleAccessibilityLabel)
    }
  }

  private struct FormattingBar: View {
    private static let overflowableItems = Array(FormattingToolbarItem.allCases.dropLast())

    private enum PopoverOwner: Equatable {
      case toolbar
      case more
      case control(FormattingToolbarItem)
    }

    private enum PresentedPopover: Identifiable, Equatable {
      case overflow([FormattingToolbarItem])
      case font
      case fontSize
      case foregroundColor
      case backgroundColor
      case webLink

      var isOverflow: Bool {
        if case .overflow = self { return true }
        return false
      }

      var id: Int {
        switch self {
        case .overflow: 0
        case .font: 1
        case .fontSize: 2
        case .foregroundColor: 3
        case .backgroundColor: 4
        case .webLink: 5
        }
      }
    }

    private enum FontSizeField: Hashable {
      case direct
      case overflow(UUID?)
    }

    private struct SolidFontSizeEdit {
      let id = UUID()
      let field: FontSizeField
      let noteID: UUID
      let revision: UInt64
      let editorGeneration: UInt64
      let selection: NSRange
      var text: String?
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.font) private var inheritedFont
    @ObservedObject var appState: AppState
    @ObservedObject var commands: EditorCommands
    @ObservedObject var dictationRuntime: DictationRuntime
    let isPinned: Bool
    let isEditorVisible: Bool
    let isTitleFocused: Bool
    let windowReserve: EdgeInsets
    let onDelete: () -> Void
    @State private var fontPickerTarget: FontPickerTarget?
    @State private var fontPickerIsSearching = false
    @State private var fontSizeText = ""
    @State private var hasUncommittedFontSizeEdit = false
    @State private var isFontSizeHovered = false
    @FocusState private var focusedFontSizeField: FontSizeField?
    @State private var fontSizePickerNoteID: UUID?
    @State private var solidFontSizeEdit: SolidFontSizeEdit?
    @State private var webLinkTarget: EditorWebLinkTarget?
    @State private var presentedPopover: PresentedPopover?
    @State private var popoverOwner: PopoverOwner = .toolbar
    @State private var requestAfterOverflow: (() -> Void)?
    @State private var selectedVisibleCount: Int?

    private var solidChrome: NotesSolidChrome {
      NotesSolidChrome(theme: theme, appearance: appState.preferences.chromeAppearance)
    }

    private var fontSizeFieldWidth: CGFloat { solidChrome.isActive ? 38 : 48 }

    var body: some View {
      MeasuredTrailingToolbarOverflow(
        itemCount: Self.overflowableItems.count,
        spacing: solidChrome.isActive ? 2 : 8,
        minimumTrailingSpacing: solidChrome.isActive ? 4 : 8,
        pinsOverflowToTrailing: solidChrome.isActive,
        onVisibleCountChange: { count in
          guard selectedVisibleCount != count else { return }
          selectedVisibleCount = count
          requestAfterOverflow = nil
          if popoverOwner == .more || presentedPopover?.isOverflow == true {
            presentedPopover = nil
          }
        }
      ) { index, measuring in
        let item = Self.overflowableItems[index]
        HStack(spacing: solidChrome.isActive ? 2 : 8) {
          if solidChrome.isActive {
            if item.rawValue >= FormattingToolbarItem.textStyles.rawValue, item.hasSeparatorBefore {
              compactSeparator.padding(.horizontal, 6)
            } else if item.hasSeparatorBefore || item == .font || item == .fontColor {
              compactSeparator.padding(.horizontal, 5)
            }
          } else if item.hasSeparatorBefore {
            Divider().frame(height: 15)
          }
          directItem(item, measuring: measuring)
        }
      } overflow: { range, measuring in
        formattingPopover(
          .more, attachedTo: overflowMenu(items: Array(Self.overflowableItems[range])),
          measuring: measuring
        )
      } trailing: { measuring in
        HStack(spacing: solidChrome.isActive ? 2 : 8) {
          if solidChrome.isActive { compactSeparator.padding(.horizontal, 5) }
          directItem(.delete, measuring: measuring)
        }
      }
      .buttonStyle(CrispToolbarButtonStyle(motion: motion))
      .animation(motion.quick, value: commands.isBold)
      .animation(motion.quick, value: commands.isItalic)
      .animation(motion.quick, value: commands.isUnderlined)
      .padding(.horizontal, solidChrome.isActive ? 9 : 16)
      .padding(.vertical, solidChrome.isActive ? 4 : 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: solidChrome.isActive ? 36 : 44)
      .frame(maxWidth: .infinity)
      .modifier(FormattingBarSurface(isPinned: isPinned))
      .padding(solidChrome.isActive
        ? solidChrome.windowEdgePadding(horizontal: 11, after: windowReserve)
        : EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
      .padding(.top, solidChrome.isActive ? 6 : 8)
      .disabled(!isEditorVisible)
      .focusEffectDisabled(!solidChrome.isActive)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Editor toolbar")
      .accessibilityHidden(!isEditorVisible)
      .popover(item: popoverBinding(for: .toolbar), arrowEdge: .bottom) { popover in
        popoverContent(popover)
          .fleckPopoverTheme(theme)
      }
      .onAppear(perform: syncFontSizeText)
      .onChange(of: commands.currentFontSize) { _, _ in syncFontSizeText() }
      .onChange(of: commands.isFontSizeMixed) { _, _ in syncFontSizeText() }
      .onChange(of: appState.selectedNote) { oldNote, newNote in
        if solidChrome.isActive && oldNote?.id != newNote?.id {
          requestAfterOverflow = nil
          presentedPopover = nil
        }
        dismissInvalidFontPicker()
        dismissInvalidFontSizePicker()
        dismissWebLinkEditor()
      }
      .onChange(of: isEditorVisible) { _, isVisible in
        if solidChrome.isActive && !isVisible {
          requestAfterOverflow = nil
          presentedPopover = nil
        }
        dismissInvalidFontPicker()
        dismissInvalidFontSizePicker()
        dismissWebLinkEditor()
      }
      .onChange(of: presentedPopover) { oldPopover, newPopover in
        if oldPopover?.isOverflow == true, newPopover == nil, let request = requestAfterOverflow {
          requestAfterOverflow = nil
          let visibleCount = selectedVisibleCount
          DispatchQueue.main.async {
            guard presentedPopover == nil, selectedVisibleCount == visibleCount, isEditorVisible,
              solidChrome.isActive
            else { return }
            request()
          }
        }
        if oldPopover == .font, newPopover != .font {
          fontPickerTarget = nil
          fontPickerIsSearching = false
        }
        if oldPopover == .fontSize, newPopover != .fontSize { fontSizePickerNoteID = nil }
        if oldPopover == .webLink, newPopover != .webLink { webLinkTarget = nil }
      }
      .onChange(of: commands.areBodyCommandsBlocked) { _, blocked in
        guard blocked else { return }
        if !solidChrome.isActive { focusedFontSizeField = nil }
        webLinkTarget?.cancel()
        if presentedPopover == .webLink { presentedPopover = nil }
      }
      .onChange(of: bodyCommandDisabled) { _, _ in
        if solidChrome.isActive { dismissInvalidFontSizePicker() }
      }
      .onChange(of: fontSizeIsDirect) { _, _ in
        if solidChrome.isActive { dismissInvalidFontSizePicker() }
      }
      .onChange(of: solidChrome.isActive) { _, isSolid in
        requestAfterOverflow = nil
        presentedPopover = nil
        guard !isSolid, let edit = solidFontSizeEdit else { return }
        discardSolidFontSize(edit.field)
        syncFontSizeText()
      }
    }

    private var compactSeparator: some View {
      Rectangle()
        .fill(solidChrome.separator)
        .frame(width: 1, height: 16)
        .accessibilityHidden(true)
    }

    private func showPopover(_ popover: PresentedPopover, from owner: PopoverOwner) {
      popoverOwner = solidChrome.isActive ? owner : .toolbar
      presentedPopover = popover
    }

    private func popoverBinding(for owner: PopoverOwner) -> Binding<PresentedPopover?> {
      Binding {
        popoverOwner == owner ? presentedPopover : nil
      } set: {
        if popoverOwner == owner { presentedPopover = $0 }
      }
    }

    @ViewBuilder
    private func formattingPopover<Trigger: View>(
      _ owner: PopoverOwner, attachedTo trigger: Trigger, measuring: Bool
    ) -> some View {
      if solidChrome.isActive && !measuring {
        trigger.background {
          NotesAnchoredPanel(item: popoverBinding(for: owner), chrome: solidChrome, theme: theme) { popover in
            popoverContent(popover)
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
        .onDisappear {
          if popoverOwner == owner { presentedPopover = nil }
        }
      } else {
        trigger
      }
    }

    @ViewBuilder
    private func directItem(_ item: FormattingToolbarItem, measuring: Bool) -> some View {
      switch item {
      case .dictation:
        dictationButton
      case .undo:
        Button {
          guard isEditorVisible else { return }
          commands.undo()
        } label: {
          ToolbarIconLabel(
            systemImage: "arrow.uturn.backward", paperGlyph: solidChrome.isActive ? .undo : nil
          )
        }
        .accessibilityLabel("Undo")
        .keyboardShortcut(measuring ? nil : KeyboardShortcut("z"))
        .disabled(!commands.canPerformEditorHistoryCommand)
      case .redo:
        Button {
          guard isEditorVisible else { return }
          commands.redo()
        } label: {
          ToolbarIconLabel(
            systemImage: "arrow.uturn.forward", paperGlyph: solidChrome.isActive ? .redo : nil
          )
        }
        .accessibilityLabel("Redo")
        .keyboardShortcut(measuring ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))
        .disabled(!commands.canPerformEditorHistoryCommand)
      case .bold:
        Button {
          guard isEditorVisible else { return }
          commands.toggleBold()
        } label: {
          ToolbarIconLabel(
            systemImage: "bold", isActive: commands.isBold,
            paperGlyph: solidChrome.isActive ? .bold : nil
          )
        }
        .accessibilityLabel("Bold")
        .accessibilityValue(
          formattingStateValue(isOn: commands.isBold, isMixed: commands.isBoldMixed)
        )
        .keyboardShortcut(measuring ? nil : KeyboardShortcut("b"))
        .disabled(bodyCommandDisabled)
      case .italic:
        Button {
          guard isEditorVisible else { return }
          commands.toggleItalic()
        } label: {
          ToolbarIconLabel(
            systemImage: "italic", isActive: commands.isItalic,
            paperGlyph: solidChrome.isActive ? .italic : nil
          )
        }
        .accessibilityLabel("Italic")
        .accessibilityValue(
          formattingStateValue(isOn: commands.isItalic, isMixed: commands.isItalicMixed)
        )
        .keyboardShortcut(measuring ? nil : KeyboardShortcut("i"))
        .disabled(bodyCommandDisabled)
      case .underline:
        Button {
          guard isEditorVisible else { return }
          commands.toggleUnderline()
        } label: {
          ToolbarIconLabel(
            systemImage: "underline", isActive: commands.isUnderlined,
            paperGlyph: solidChrome.isActive ? .underline : nil
          )
        }
        .accessibilityLabel("Underline")
        .accessibilityValue(
          formattingStateValue(isOn: commands.isUnderlined, isMixed: commands.isUnderlineMixed)
        )
        .keyboardShortcut(measuring ? nil : KeyboardShortcut("u"))
        .disabled(bodyCommandDisabled)
      case .strikethrough:
        Button {
          guard isEditorVisible else { return }
          commands.toggleStrikethrough()
        } label: {
          ToolbarIconLabel(
            systemImage: "strikethrough", isActive: commands.isStrikethrough,
            paperGlyph: solidChrome.isActive ? .strikethrough : nil
          )
        }
        .accessibilityLabel("Strikethrough")
        .accessibilityValue(
          formattingStateValue(
            isOn: commands.isStrikethrough,
            isMixed: commands.isStrikethroughMixed
          )
        )
        .disabled(bodyCommandDisabled)
      case .font:
        formattingPopover(.control(.font), attachedTo: fontButton, measuring: measuring)
      case .fontSize:
        if measuring {
          Color.clear.frame(width: fontSizeFieldWidth, height: 0)
        } else {
          fontSizeField().disabled(bodyCommandDisabled)
        }
      case .fontColor:
        formattingPopover(.control(.fontColor), attachedTo: foregroundColorButton, measuring: measuring)
      case .highlight:
        formattingPopover(.control(.highlight), attachedTo: backgroundColorButton, measuring: measuring)
      case .bullets:
        bulletsButton
      case .numbers:
        numbersButton
      case .checklist:
        Button {
          guard isEditorVisible else { return }
          commands.applyList(.checklist)
        } label: {
          ToolbarIconLabel(systemImage: "checklist", paperGlyph: solidChrome.isActive ? .checklist : nil)
        }
        .accessibilityLabel("Checklist")
        .disabled(bodyCommandDisabled)
      case .textStyles, .text, .paragraph:
        directFormattingMenu(item)
      case .tools:
        formattingPopover(
          .control(.tools), attachedTo: toolsInsertMenu,
          measuring: measuring
        )
      case .delete:
        Button(role: .destructive) {
          guard isEditorVisible else { return }
          onDelete()
        } label: {
          ToolbarIconLabel(systemImage: "trash", paperGlyph: solidChrome.isActive ? .editorTrash : nil)
        }
        .accessibilityLabel("Delete")
        .keyboardShortcut(measuring || solidChrome.isActive ? nil : KeyboardShortcut("w"))
      }
    }

    private var dictationButton: some View {
      Menu {
        Button("Cancel Dictation", role: .destructive) {
          guard isEditorVisible else { return }
          Task { await dictationRuntime.cancel() }
        }
        .disabled(!dictationRuntime.canCancel)
      } label: {
        ToolbarIconLabel(
          systemImage: dictationRuntime.microphoneSymbol,
          isActive: dictationRuntime.isListening,
          paperGlyph: solidChrome.isActive && !dictationRuntime.isListening ? .microphone : nil
        )
      } primaryAction: {
        performDictationPrimaryAction()
      }
      .accessibilityLabel(dictationRuntime.microphoneHelp)
      .accessibilityAction(named: Text("Cancel Dictation")) {
        guard isEditorVisible else { return }
        Task { await dictationRuntime.cancel() }
      }
      .help(dictationRuntime.microphoneHelp)
    }

    private var fontButton: some View {
      Button { presentFontPicker(from: .control(.font)) } label: {
        HStack(spacing: 5) {
          Text(fontFamilyDisplay).lineLimit(1).truncationMode(.tail)
          if solidChrome.isActive {
            Spacer(minLength: 4)
            NotesPaperIcon(glyph: .fontDisclosure)
          } else {
            Image(systemName: "chevron.down").font(.system(size: 8))
              .accessibilityHidden(true)
          }
        }
        .font(solidChrome.isActive ? .system(size: 12) : inheritedFont)
        .padding(.horizontal, solidChrome.isActive ? 8 : 0)
        .frame(width: solidChrome.isActive ? 110 : 112, height: solidChrome.isActive ? 28 : nil)
        .background(
          solidChrome.isActive ? solidChrome.toolbarField : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
      }
      .help("Font: \(fontFamilyDisplay)")
      .accessibilityLabel("Font")
      .accessibilityValue(fontFamilyDisplay)
    }

    private var foregroundColorButton: some View {
      Button {
        guard isEditorVisible else { return }
        showPopover(.foregroundColor, from: .control(.fontColor))
      } label: {
        ToolbarIconLabel(systemImage: "paintpalette", paperGlyph: solidChrome.isActive ? .palette : nil)
      }
      .accessibilityLabel("Font Color")
      .accessibilityValue(
        colorAccessibilityValue(
          color: commands.currentForegroundColor,
          isMixed: commands.isForegroundColorMixed,
          emptyName: "Automatic"
        )
      )
      .disabled(bodyCommandDisabled)
    }

    private var backgroundColorButton: some View {
      Button {
        guard isEditorVisible else { return }
        showPopover(.backgroundColor, from: .control(.highlight))
      } label: {
        if solidChrome.isActive {
          NotesPaperIcon(
            glyph: .highlighter,
            highlightInk: commands.isBackgroundColorMixed ? nil : commands.currentBackgroundColor.map(Color.init(nsColor:))
          )
          .frame(width: 28, height: 26)
          .contentShape(RoundedRectangle(cornerRadius: 5))
        } else {
          HighlighterMarkerIcon(
            backgroundColor: commands.currentBackgroundColor,
            isMixed: commands.isBackgroundColorMixed
          )
        }
      }
      .accessibilityLabel("Highlight")
      .accessibilityValue(
        colorAccessibilityValue(
          color: commands.currentBackgroundColor,
          isMixed: commands.isBackgroundColorMixed,
          emptyName: "No Highlight"
        )
      )
      .disabled(bodyCommandDisabled)
    }

    private var bulletsButton: some View {
      Menu {
        NotesNativeMenuItems(items: listMenuItems(.bullets, includeAutomatic: false))
      } label: {
        ToolbarIconLabel(systemImage: "list.bullet", paperGlyph: solidChrome.isActive ? .bullets : nil)
      } primaryAction: {
        guard isEditorVisible else { return }
        commands.applyAutomaticList(.bullets)
      }
      .accessibilityLabel("Bullets")
      .disabled(bodyCommandDisabled)
    }

    private var numbersButton: some View {
      Menu {
        NotesNativeMenuItems(items: listMenuItems(.numbers, includeAutomatic: false))
      } label: {
        ToolbarIconLabel(systemImage: "list.number", paperGlyph: solidChrome.isActive ? .numbers : nil)
      } primaryAction: {
        guard isEditorVisible else { return }
        commands.applyAutomaticList(.numbers)
      }
      .accessibilityLabel("Numbers")
      .disabled(bodyCommandDisabled)
    }

    private var isMorePopoverOpen: Bool {
      presentedPopover?.isOverflow == true
        || (solidChrome.isActive && popoverOwner == .more && presentedPopover != nil)
    }

    private func overflowMenu(items: [FormattingToolbarItem]) -> some View {
      Button {
        if isMorePopoverOpen { presentedPopover = nil }
        else { showPopover(.overflow(items), from: .more) }
      } label: {
        FormattingOverflowLabel()
          .background {
            if solidChrome.isActive && isMorePopoverOpen {
              RoundedRectangle(cornerRadius: 5)
                .fill(solidChrome.popoverSelection)
            }
          }
      }
      .accessibilityLabel("More formatting")
      .onKeyPress(.downArrow) {
        guard solidChrome.isActive, isEditorVisible, !isMorePopoverOpen else { return .ignored }
        showPopover(.overflow(items), from: .more)
        return .handled
      }
    }

    @ViewBuilder
    private func popoverContent(_ popover: PresentedPopover) -> some View {
      switch popover {
      case .overflow(let items):
        if solidChrome.isActive {
          NotesFormattingCascade(items: overflowItems(items), chrome: solidChrome) {
            presentedPopover = nil
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
              if item != items.first, item.hasSeparatorBefore { Divider() }
              NotesNativeMenuItem(item: overflowItem(item),
                displayTitle: item == .textStyles ? commands.currentTextStyle?.rawValue : nil)
            }
          }
          .buttonStyle(.plain)
          .frame(minWidth: 180, alignment: .leading)
          .padding(10)
        }
      case .font:
        fontPickerContent
      case .fontSize:
        fontSizePickerContent
      case .foregroundColor:
        foregroundColorPickerContent
      case .backgroundColor:
        backgroundColorPickerContent
      case .webLink:
        webLinkPickerContent
      }
    }

    private func overflowItems(_ items: [FormattingToolbarItem]) -> [NotesCascadeItem?] {
      items.flatMap { item in
        let row = overflowItem(item)
        return item == .tools && item != items.first ? [nil, row] : [row]
      }
    }

    private func overflowItem(_ item: FormattingToolbarItem) -> NotesCascadeItem {
      let enabled = !bodyCommandDisabled
      switch item {
      case .dictation:
        return NotesCascadeItem("Dictation", icon: "waveform", isEnabled: isEditorVisible, items: [
          NotesCascadeItem(dictationRuntime.microphoneHelp,
            isEnabled: dictationRuntime.toolbarPresentation.primaryAction != nil) {
            presentedPopover = nil
            performDictationPrimaryAction()
          },
          NotesCascadeItem("Cancel Dictation", isEnabled: dictationRuntime.canCancel, role: .destructive) {
            guard isEditorVisible else { return }
            presentedPopover = nil
            Task { await dictationRuntime.cancel() }
          },
        ])
      case .undo:
        return NotesCascadeItem("Undo", shortcut: KeyboardShortcut("z"),
          isEnabled: commands.canPerformEditorHistoryCommand) {
          performOverflowAction { commands.undo() }
        }
      case .redo:
        return NotesCascadeItem("Redo", shortcut: KeyboardShortcut("z", modifiers: [.command, .shift]),
          isEnabled: commands.canPerformEditorHistoryCommand) {
          performOverflowAction { commands.redo() }
        }
      case .bold:
        return NotesCascadeItem("Bold", value: formattingStateValue(isOn: commands.isBold, isMixed: commands.isBoldMixed),
          shortcut: KeyboardShortcut("b"), isEnabled: enabled) {
          performOverflowAction { commands.toggleBold() }
        }
      case .italic:
        return NotesCascadeItem("Italic",
          value: formattingStateValue(isOn: commands.isItalic, isMixed: commands.isItalicMixed),
          shortcut: KeyboardShortcut("i"), isEnabled: enabled) {
          performOverflowAction { commands.toggleItalic() }
        }
      case .underline:
        return NotesCascadeItem("Underline",
          value: formattingStateValue(isOn: commands.isUnderlined, isMixed: commands.isUnderlineMixed),
          shortcut: KeyboardShortcut("u"), isEnabled: enabled) {
          performOverflowAction { commands.toggleUnderline() }
        }
      case .strikethrough:
        return NotesCascadeItem("Strikethrough",
          value: formattingStateValue(isOn: commands.isStrikethrough, isMixed: commands.isStrikethroughMixed),
          isEnabled: enabled) {
          performOverflowAction { commands.toggleStrikethrough() }
        }
      case .font:
        return NotesCascadeItem("Font…", accessibilityLabel: "Font", value: fontFamilyDisplay,
          isEnabled: isEditorVisible) {
          presentOverflowPicker { presentFontPicker(from: .more) }
        }
      case .fontSize:
        return NotesCascadeItem("Font Size…", accessibilityLabel: "Font Size",
          value: commands.isFontSizeMixed ? "Mixed" : fontSizeDisplay, isEnabled: enabled,
          perform: presentFontSizePicker)
      case .fontColor:
        return NotesCascadeItem("Font Color…", accessibilityLabel: "Font Color",
          value: colorAccessibilityValue(color: commands.currentForegroundColor,
            isMixed: commands.isForegroundColorMixed, emptyName: "Automatic"),
          isEnabled: enabled) {
          presentOverflowPicker { showPopover(.foregroundColor, from: .more) }
        }
      case .highlight:
        return NotesCascadeItem("Highlight…", accessibilityLabel: "Highlight",
          value: colorAccessibilityValue(color: commands.currentBackgroundColor,
            isMixed: commands.isBackgroundColorMixed, emptyName: "No Highlight"),
          isEnabled: enabled) {
          presentOverflowPicker { showPopover(.backgroundColor, from: .more) }
        }
      case .bullets:
        return NotesCascadeItem("Bullets", icon: "list.bullet", isEnabled: enabled,
          items: listMenuItems(.bullets, includeAutomatic: true))
      case .numbers:
        return NotesCascadeItem("Numbers", icon: "list.number", isEnabled: enabled,
          items: listMenuItems(.numbers, includeAutomatic: true))
      case .checklist:
        return NotesCascadeItem("Checklist", isEnabled: enabled) {
          performOverflowAction { commands.applyList(.checklist) }
        }
      case .textStyles, .text, .paragraph:
        return formattingBranch(item, fromOverflow: true)
      case .tools:
        return NotesCascadeItem("Tools / Insert", icon: "link", help: "Links and find tools",
          isEnabled: enabled, items: toolsInsertActions(fromOverflow: true))
      case .delete:
        return NotesCascadeItem("Delete", shortcut: solidChrome.isActive ? nil : KeyboardShortcut("w"),
          isEnabled: enabled, role: .destructive) {
          performOverflowAction(onDelete)
        }
      }
    }

    private func listMenuItems(_ family: EditorListFamily, includeAutomatic: Bool) -> [NotesCascadeItem?] {
      let variants: [(String, EditorListStyle)] = family == .bullets
        ? [("Disc (•)", .bullet(.disc)), ("Circle (◦)", .bullet(.circle)),
          ("Square (▪)", .bullet(.square)), ("Dash (–)", .bullet(.dash))]
        : [("Decimal (1.)", .number(.decimal)), ("Alphabetic (a.)", .number(.alphabetic)),
          ("Roman (i.)", .number(.roman))]
      let styles = variants.map { label, style in
        NotesCascadeItem(label) {
          performListAction(fromOverflow: includeAutomatic) { commands.applyList(style) }
        }
      }
      guard includeAutomatic else { return styles.map(Optional.some) }
      return [
        NotesCascadeItem(family == .bullets ? "Bulleted List" : "Numbered List") {
          performListAction(fromOverflow: true) { commands.applyAutomaticList(family) }
        },
        nil,
      ] + styles.map(Optional.some)
    }

    private func directFormattingMenu(_ item: FormattingToolbarItem) -> some View {
      let branch = formattingBranch(item, fromOverflow: false)
      return Menu {
        if case .submenu(let children) = branch.action { NotesNativeMenuItems(items: children) }
      } label: {
        switch item {
        case .textStyles: ToolbarIconLabel(systemImage: "textformat.size")
        case .text: FormattingMenuIconLabel(systemImage: "textformat.alt")
        default: FormattingMenuIconLabel(systemImage: "arrow.up.and.down.text.horizontal")
        }
      }
      .menuIndicator(item == .textStyles ? .automatic : .hidden)
      .disabled(!branch.isEnabled)
      .accessibilityLabel(branch.title)
      .accessibilityValue(branch.value ?? "")
      .help(branch.help ?? "")
    }

    private func formattingBranch(_ item: FormattingToolbarItem, fromOverflow: Bool) -> NotesCascadeItem {
      let perform = { (command: () -> Void) in
        if fromOverflow && solidChrome.isActive { performOverflowAction(command) }
        else { command() }
      }
      switch item {
      case .textStyles:
        return NotesCascadeItem("Text Style", icon: "text.book.closed", help: "Apply durable visual paragraph styling",
          value: commands.currentTextStyle?.rawValue ?? "Mixed or custom", isEnabled: !bodyCommandDisabled,
          items: EditorTextStyle.allCases.map { style in
            NotesCascadeItem(style.rawValue, isSelected: commands.currentTextStyle == style) {
              perform { _ = commands.applyTextStyle(style) }
            }
          })
      case .text:
        return NotesCascadeItem("Text", icon: "bold", help: "Text formatting", isEnabled: !bodyCommandDisabled,
          items: [
            NotesCascadeItem("Clear Text Formatting") { perform { _ = commands.clearTextFormatting() } },
            nil,
            NotesCascadeItem("Copy Formatting",
              help: "Copies the first selected run's visual formatting without using the clipboard.") {
              perform { _ = commands.copyFormatting() }
            },
            NotesCascadeItem("Paste Formatting", isEnabled: commands.canPasteFormatting) {
              perform { _ = commands.pasteFormatting() }
            },
            NotesCascadeItem("Cancel Copied Formatting", isEnabled: commands.canPasteFormatting) {
              perform { commands.cancelCopiedFormatting() }
            },
            nil,
            NotesCascadeItem(commands.currentBaseline == nil ? "Baseline (Mixed)" : "Baseline",
              items: EditorBaseline.allCases.map { baseline in
                NotesCascadeItem(baseline.rawValue, isSelected: commands.currentBaseline == baseline) {
                  perform { _ = commands.setBaseline(baseline) }
                }
              }),
            NotesCascadeItem("Change Case", help: "Uses locale-neutral Unicode case conversion.",
              items: EditorTextCase.allCases.map { textCase in
                NotesCascadeItem(textCase.rawValue, isEnabled: commands.textView?.selectedRange().length != 0) {
                  perform { _ = commands.transformCase(textCase) }
                }
              }),
          ])
      default:
        let alignments: [(String, NSTextAlignment)] = [
          ("Left", .left), ("Center", .center), ("Right", .right), ("Justified", .justified),
        ]
        let spacing = [true, false].map { before in
          let current = before ? commands.currentParagraphSpacingBefore : commands.currentParagraphSpacingAfter
          let title = before ? "Space Before" : "Space After"
          return NotesCascadeItem(current == nil ? title + " (Mixed or Custom)" : title,
            items: stride(from: 0, through: 36, by: 6).map { points in
              NotesCascadeItem("\(points) pt", isSelected: current == CGFloat(points)) {
                perform {
                  if before { _ = commands.applyParagraphSpacingBefore(CGFloat(points)) }
                  else { _ = commands.applyParagraphSpacingAfter(CGFloat(points)) }
                }
              }
            })
        }
        return NotesCascadeItem("Paragraph", icon: "list.bullet", help: "Paragraph formatting",
          isEnabled: !bodyCommandDisabled, items: [
            NotesCascadeItem(commands.isAlignmentMixed ? "Alignment (Mixed)" : "Alignment",
              items: alignments.map { title, alignment in
                NotesCascadeItem(title, isSelected: commands.currentAlignment == alignment) {
                  perform { _ = commands.applyAlignment(alignment) }
                }
              }),
            NotesCascadeItem(commands.currentLineSpacing == nil ? "Line Spacing (Mixed or Custom)" : "Line Spacing",
              items: EditorLineSpacing.allCases.map { lineSpacing in
                NotesCascadeItem(lineSpacing.rawValue, isSelected: commands.currentLineSpacing == lineSpacing) {
                  perform { _ = commands.applyLineSpacing(lineSpacing) }
                }
              }),
            spacing[0], spacing[1], nil,
            NotesCascadeItem("Increase Indent") { perform { _ = commands.increaseIndent() } },
            NotesCascadeItem("Decrease Indent") { perform { _ = commands.decreaseIndent() } },
          ])
      }
    }

    private func toolsInsertActions(fromOverflow: Bool) -> [NotesCascadeItem?] {
      let perform = { (command: () -> Void) in
        if solidChrome.isActive { performOverflowAction(command) }
        else { command() }
      }
      return [
        NotesCascadeItem("Web Link…", paperGlyph: .backlinks) {
          if solidChrome.isActive && fromOverflow { presentWebLinkEditor(afterOverflow: true) }
          else { perform { presentWebLinkEditor() } }
        },
        NotesCascadeItem("Link to Note…", paperGlyph: .toolsDocument) {
          guard isEditorVisible, let textView = commands.textView as? ListAwareTextView,
            let note = appState.selectedNote
          else { return }
          let range = textView.selectedRange()
          let request = { [weak textView] in
            guard let textView, commands.textView === textView,
              appState.selectedNote?.id == note.id, appState.selectedNote?.revision == note.revision
            else { return }
            textView.onRequestNoteLink?(range)
          }
          if solidChrome.isActive && fromOverflow {
            requestAfterOverflow = request
            presentedPopover = nil
          } else {
            request()
          }
        },
        nil,
        NotesCascadeItem("Find in Note", paperGlyph: .search) { perform { _ = commands.performFind(.showFind) } },
        NotesCascadeItem("Replace in Note", paperGlyph: .toolsReplace) { perform { _ = commands.performFind(.showReplace) } },
        NotesCascadeItem("Find Next", paperGlyph: .fontDisclosure) { perform { _ = commands.performFind(.nextMatch) } },
        NotesCascadeItem("Find Previous", paperGlyph: .chevron) { perform { _ = commands.performFind(.previousMatch) } },
      ]
    }

    @ViewBuilder private var toolsInsertMenu: some View {
      let actions = toolsInsertActions(fromOverflow: false)
      let icon = FormattingMenuIconLabel(systemImage: "wrench.adjustable")
      if solidChrome.isActive {
        NotesToolsMenu(title: "Tools", chrome: solidChrome, actions: actions) { icon }
        .disabled(bodyCommandDisabled)
        .help("Links and find tools")
      } else {
        Menu {
          NotesNativeMenuItems(items: actions)
        } label: {
          icon
        }
        .menuIndicator(.hidden)
        .disabled(bodyCommandDisabled)
        .accessibilityLabel("Tools")
        .help("Links and find tools")
      }
    }

    private var bodyCommandDisabled: Bool {
      !isEditorVisible || isTitleFocused || commands.isTitleEditing
        || !commands.canPerformBodyCommand
    }

    @ViewBuilder
    private var fontPickerContent: some View {
      if let target = fontPickerTarget {
        let isMixed = !target.isTitle && commands.isFontFamilyMixed
        let isCurrentPresentation = {
          !solidChrome.isActive || (presentedPopover == .font && fontPickerTarget === target)
        }
        FontFamilyPicker(
          currentFamily: target.isTitle
            ? target.note.titleFontFamily ?? appState.preferences.fontFamily
            : commands.currentFontFamily,
          isMixed: isMixed,
          targetLabel: target.label,
          notesChrome: solidChrome.isActive ? solidChrome : nil,
          onSearchChanged: {
            if isCurrentPresentation() { fontPickerIsSearching = $0 }
          },
          onCommit: { family in
            guard isCurrentPresentation() else { return }
            _ = target.apply(
              family,
              note: appState.selectedNote,
              isEditorVisible: isEditorVisible,
              commands: commands,
              titleMutation: {
                appState.setTitleFontFamily(
                  $0,
                  noteID: target.note.id,
                  undoManager: target.undoManager
                )
              }
            )
            presentedPopover = nil
          },
          onCancel: {
            if isCurrentPresentation() { presentedPopover = nil }
          }
        )
        .id(solidChrome.isActive ? ObjectIdentifier(target) : nil)
        .frame(width: 280, height: FontFamilyPickerController.presentationHeight(
          isCompact: solidChrome.isActive, isMixed: isMixed, isSearching: fontPickerIsSearching
        ))
      }
    }

    private var fontSizePickerContent: some View {
      Group {
        if solidChrome.isActive {
          if let edit = solidFontSizeEdit, case .overflow = edit.field {
            SolidOverflowSizeDraft { draft in
              HStack(spacing: 8) {
                fontSizeField(field: edit.field, overflowDraft: draft)
                Button("Done") {
                  submitSolidFontSize(edit.field, dismissPicker: true, overflowDraft: draft.wrappedValue)
                }
              }
              .padding(12)
              .task(id: edit.field) {
                guard solidFontSizeEdit?.id == edit.id, isCurrentSolidFontSizeEdit(edit),
                  presentedPopover == .fontSize
                else { return }
                focusedFontSizeField = edit.field
              }
            }
            .id(edit.field)
          }
        } else if let targetNoteID = fontSizePickerNoteID {
          HStack(spacing: 8) {
            fontSizeField(field: .overflow(nil), targetNoteID: targetNoteID)
            Button("Done") {
              applyFontSizeText(targetNoteID: targetNoteID)
              presentedPopover = nil
            }
          }
          .padding(12)
        }
      }
    }

    private var foregroundColorPickerContent: some View {
      FleckColorPicker(
        currentHex: commands.isForegroundColorMixed
          ? nil
          : FleckColorHex.hex(from: commands.currentForegroundColor),
        currentLabel: colorAccessibilityValue(
          color: commands.currentForegroundColor,
          isMixed: commands.isForegroundColorMixed,
          emptyName: "Automatic"
        ),
        resetTitle: "Automatic",
        onCommit: { hex in
          guard isEditorVisible else {
            presentedPopover = nil
            return
          }
          commands.applyForegroundColor(hex.flatMap { NSColor(hex: $0) })
          presentedPopover = nil
        },
        onCancel: { presentedPopover = nil }
      )
    }

    private var backgroundColorPickerContent: some View {
      FleckColorPicker(
        currentHex: commands.isBackgroundColorMixed
          ? nil
          : FleckColorHex.hex(from: commands.currentBackgroundColor),
        currentLabel: colorAccessibilityValue(
          color: commands.currentBackgroundColor,
          isMixed: commands.isBackgroundColorMixed,
          emptyName: "No Highlight"
        ),
        resetTitle: "No Highlight",
        fallbackHex: "#FFD600",
        onCommit: { hex in
          guard isEditorVisible else {
            presentedPopover = nil
            return
          }
          commands.applyBackgroundColor(hex.flatMap { NSColor(hex: $0) })
          presentedPopover = nil
        },
        onCancel: { presentedPopover = nil }
      )
    }

    @ViewBuilder
    private var webLinkPickerContent: some View {
      if let target = webLinkTarget {
        EditorWebLinkPopover(
          target: target,
          notesChrome: solidChrome,
          onApply: { url, display in
            target.apply(
              urlText: url,
              displayText: display,
              note: appState.selectedNote,
              isEditorVisible: isEditorVisible,
              commands: commands
            )
          },
          onRemove: {
            target.remove(
              note: appState.selectedNote,
              isEditorVisible: isEditorVisible,
              commands: commands
            )
          },
          onCancel: {
            target.cancel()
            presentedPopover = nil
          }
        )
      }
    }

    private func performDictationPrimaryAction() {
      guard isEditorVisible,
        dictationRuntime.toolbarPresentation.primaryAction != nil
      else { return }
      Task { await dictationRuntime.toggle() }
    }

    private func performOverflowAction(_ action: () -> Void) {
      guard isEditorVisible else { return }
      presentedPopover = nil
      action()
    }

    private func performListAction(
      fromOverflow: Bool,
      _ action: () -> Void
    ) {
      if fromOverflow {
        performOverflowAction(action)
      } else if isEditorVisible {
        action()
      }
    }

    private func presentOverflowPicker(
      _ action: @escaping @MainActor @Sendable () -> Void
    ) {
      guard isEditorVisible else { return }
      if solidChrome.isActive && presentedPopover?.isOverflow == true {
        let note = appState.selectedNote
        requestAfterOverflow = {
          guard let note, appState.selectedNote?.id == note.id,
            appState.selectedNote?.revision == note.revision
          else { return }
          action()
        }
        presentedPopover = nil
        return
      }
      presentedPopover = nil
      DispatchQueue.main.async(execute: action)
    }

    private func presentFontPicker(from owner: PopoverOwner) {
      guard isEditorVisible, let note = appState.selectedNote else { return }
      if solidChrome.isActive { fontPickerIsSearching = false }
      fontPickerTarget = FontPickerTarget(
        note: note,
        isTitle: isFontTitleTarget,
        commands: commands,
        preservedFamily: solidChrome.isActive && !isFontFamilyMixed ? currentFontFamily : nil
      )
      if fontPickerTarget != nil { showPopover(.font, from: owner) }
    }

    private func presentWebLinkEditor(afterOverflow: Bool = false) {
      guard !bodyCommandDisabled, let note = appState.selectedNote,
        let target = EditorWebLinkTarget(note: note, commands: commands)
      else { return }
      if afterOverflow, presentedPopover?.isOverflow == true {
        requestAfterOverflow = {
          guard presentedPopover == nil, target.isValid(
            note: appState.selectedNote,
            isEditorVisible: isEditorVisible,
            commands: commands
          ) else { return }
          webLinkTarget = target
          showPopover(.webLink, from: .more)
        }
        presentedPopover = nil
      } else {
        webLinkTarget = target
        showPopover(.webLink, from: .control(.tools))
      }
    }

    private func dismissWebLinkEditor() {
      guard let target = webLinkTarget else { return }
      if !target.isValid(
        note: appState.selectedNote,
        isEditorVisible: isEditorVisible,
        commands: commands
      ) {
        target.cancel()
        if presentedPopover == .webLink { presentedPopover = nil }
        webLinkTarget = nil
      }
    }

    private var motion: AppMotion {
      AppMotion(reduceMotion: reduceMotion)
    }

    private var fontSizeDisplay: String {
      guard !commands.isFontSizeMixed, let size = commands.currentFontSize else { return "" }
      return String(format: "%.2f", size).replacingOccurrences(of: #"\.00$"#, with: "", options: .regularExpression)
    }

    private func fontSizeField(
      field: FontSizeField = .direct, targetNoteID: UUID? = nil,
      overflowDraft: Binding<String?>? = nil
    ) -> some View {
      let isFontSizeFocused = focusedFontSizeField == field
      let handlesEscape = solidChrome.isActive && (isFontSizeFocused || overflowDraft != nil)
      return TextField(
        "Size",
        text: Binding(
          get: {
            guard solidChrome.isActive else { return fontSizeText }
            return overflowDraft?.wrappedValue
              ?? (solidFontSizeEdit?.field == field ? solidFontSizeEdit?.text : nil)
              ?? fontSizeDisplay
          },
          set: { value in
            if solidChrome.isActive {
              if let overflowDraft {
                if value != (overflowDraft.wrappedValue ?? fontSizeDisplay) {
                  overflowDraft.wrappedValue = value
                }
                return
              }
              guard focusedFontSizeField == field, let edit = solidFontSizeEdit,
                edit.field == field, isCurrentSolidFontSizeEdit(edit),
                value != (edit.text ?? fontSizeDisplay)
              else { return }
              solidFontSizeEdit?.text = value
              return
            }
            guard value != fontSizeText else { return }
            fontSizeText = value
            hasUncommittedFontSizeEdit = true
          }
        ),
        prompt: Text(commands.isFontSizeMixed ? "Mixed" : "Size")
      )
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .multilineTextAlignment(.center)
        .monospacedDigit()
        .font(solidChrome.isActive
          ? .system(size: 12, weight: solidChrome.increasedContrast ? .regular : .light)
          : inheritedFont)
        .frame(width: fontSizeFieldWidth, height: solidChrome.isActive ? 28 : nil)
        .background(
          solidChrome.isActive ? solidChrome.toolbarField : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .focused($focusedFontSizeField, equals: field)
        .overlay(alignment: .bottom) {
          if solidChrome.isActive {
            RoundedRectangle(cornerRadius: 5)
              .strokeBorder(
                isFontSizeFocused ? theme.color(.focusRing).opacity(solidChrome.increasedContrast ? 1 : 0.65)
                  : isFontSizeHovered ? Color.primary.opacity(0.22) : .clear,
                lineWidth: 1
              )
              .allowsHitTesting(false)
          } else {
            Rectangle()
              .fill(
                isFontSizeFocused
                  ? theme.color(.accent)
                  : isFontSizeHovered ? Color.primary.opacity(0.22) : .clear
              )
              .frame(height: isFontSizeFocused ? 1.5 : 1)
              .padding(.horizontal, 4)
          }
        }
        .onHover { isFontSizeHovered = $0 }
        .onExitCommand(perform: handlesEscape ? {
          if overflowDraft != nil || focusedFontSizeField == field { discardSolidFontSize(field) }
        } : nil)
        .onKeyPress(.escape) {
          guard handlesEscape else { return .ignored }
          discardSolidFontSize(field)
          return .handled
        }
        .onChange(of: focusedFontSizeField) { oldField, newField in
          if solidChrome.isActive {
            if newField == field, field == .direct {
              solidFontSizeEdit = makeSolidFontSizeEdit(for: field)
            } else if field == .direct, oldField == field, let edit = solidFontSizeEdit, edit.field == field {
              DispatchQueue.main.async {
                guard focusedFontSizeField != field, solidFontSizeEdit?.id == edit.id else { return }
                submitSolidFontSize(field, dismissPicker: false)
              }
            }
          } else if oldField == field && newField != field {
            applyFontSizeText(targetNoteID: targetNoteID)
          }
        }
        .onSubmit {
          if solidChrome.isActive {
            guard overflowDraft != nil || focusedFontSizeField == field else { return }
            submitSolidFontSize(field, dismissPicker: field != .direct, overflowDraft: overflowDraft?.wrappedValue)
          } else {
            applyFontSizeText(targetNoteID: targetNoteID)
          }
        }
        .onDisappear {
          if solidChrome.isActive {
            discardSolidFontSize(field, dismissPicker: false)
          } else if targetNoteID != nil {
            applyFontSizeText(targetNoteID: targetNoteID)
          }
        }
        .accessibilityLabel("Font size")
        .accessibilityValue(
          overflowDraft?.wrappedValue
            ?? (solidChrome.isActive && solidFontSizeEdit?.field == field ? solidFontSizeEdit?.text : nil)
            ?? (commands.isFontSizeMixed ? "Mixed" : fontSizeDisplay)
        )
        .accessibilityHint("Enter a size from 1 through 512 points.")
    }

    private var isFontTitleTarget: Bool {
      commands.isTitleEditing || isTitleFocused
    }

    private var currentFontFamily: String? {
      if isFontTitleTarget {
        return appState.selectedNote?.titleFontFamily ?? appState.preferences.fontFamily
      }
      return commands.currentFontFamily
    }

    private var isFontFamilyMixed: Bool {
      isFontTitleTarget ? false : commands.isFontFamilyMixed
    }

    private var fontFamilyDisplay: String {
      isFontFamilyMixed ? "Mixed fonts" : FontFamilyPickerController.displayName(currentFontFamily ?? ".AppleSystemUIFont")
    }

    private func dismissInvalidFontPicker() {
      guard let target = fontPickerTarget else { return }
      if !target.isValid(note: appState.selectedNote, isEditorVisible: isEditorVisible, commands: commands) {
        presentedPopover = nil
      }
    }

    private func syncFontSizeText() {
      guard focusedFontSizeField == nil else { return }
      fontSizeText = fontSizeDisplay
    }

    private func presentFontSizePicker() {
      if solidChrome.isActive {
        guard !fontSizeIsDirect, let edit = makeSolidFontSizeEdit(for: .overflow(UUID())) else { return }
        solidFontSizeEdit = edit
        presentOverflowPicker {
          guard presentedPopover == nil, solidFontSizeEdit?.id == edit.id,
            isCurrentSolidFontSizeEdit(edit)
          else { return }
          showPopover(.fontSize, from: .more)
        }
      } else {
        presentOverflowPicker {
          guard isEditorVisible, let noteID = appState.selectedNote?.id else { return }
          fontSizePickerNoteID = noteID
          syncFontSizeText()
          showPopover(.fontSize, from: .more)
        }
      }
    }

    private func dismissInvalidFontSizePicker() {
      if solidChrome.isActive {
        if let edit = solidFontSizeEdit, !isCurrentSolidFontSizeEdit(edit) {
          discardSolidFontSize(edit.field)
        }
        return
      }
      guard presentedPopover == .fontSize,
        !isEditorVisible || fontSizePickerNoteID != appState.selectedNote?.id
      else { return }
      focusedFontSizeField = nil
      presentedPopover = nil
    }

    private var fontSizeIsDirect: Bool {
      (selectedVisibleCount ?? 0) > FormattingToolbarItem.fontSize.rawValue
    }

    private func makeSolidFontSizeEdit(for field: FontSizeField) -> SolidFontSizeEdit? {
      guard !bodyCommandDisabled, let note = appState.selectedNote, let textView = commands.textView
      else { return nil }
      return SolidFontSizeEdit(
        field: field, noteID: note.id, revision: note.revision,
        editorGeneration: commands.editorSessionGeneration, selection: textView.selectedRange()
      )
    }

    private func isCurrentSolidFontSizeEdit(_ edit: SolidFontSizeEdit) -> Bool {
      guard solidChrome.isActive, !bodyCommandDisabled, appState.preferences.showFormattingBar,
        fontSizeIsDirect == (edit.field == .direct), let note = appState.selectedNote,
        note.id == edit.noteID, note.revision == edit.revision
      else { return false }
      return commands.editorSessionGeneration == edit.editorGeneration
        && commands.textView?.selectedRange() == edit.selection
    }

    private func discardSolidFontSize(_ field: FontSizeField, dismissPicker: Bool = true) {
      guard solidFontSizeEdit?.field == field else { return }
      solidFontSizeEdit = nil
      if focusedFontSizeField == field { focusedFontSizeField = nil }
      if dismissPicker, field != .direct, presentedPopover == .fontSize { presentedPopover = nil }
    }

    private func submitSolidFontSize(_ field: FontSizeField, dismissPicker: Bool, overflowDraft: String? = nil) {
      guard let edit = solidFontSizeEdit, edit.field == field else { return }
      guard isCurrentSolidFontSizeEdit(edit), field == .direct || presentedPopover == .fontSize
      else {
        discardSolidFontSize(field)
        return
      }
      solidFontSizeEdit?.text = nil
      if let text = field == .direct ? edit.text : overflowDraft,
        let size = FontSizeSubmission.requestedSize(
          for: text, currentSize: commands.currentFontSize, isMixed: commands.isFontSizeMixed
        )
      {
        _ = commands.applyFontSize(size)
        if !dismissPicker, let nextEdit = makeSolidFontSizeEdit(for: field) {
          solidFontSizeEdit = nextEdit
        }
      }
      if dismissPicker || (field == .direct && focusedFontSizeField != field) {
        discardSolidFontSize(field)
      }
    }

    private func applyFontSizeText(targetNoteID: UUID? = nil) {
      guard isEditorVisible,
        targetNoteID == nil || targetNoteID == appState.selectedNote?.id
      else { return }
      if hasUncommittedFontSizeEdit {
        hasUncommittedFontSizeEdit = false
        if let size = FontSizeSubmission.requestedSize(
          for: fontSizeText,
          currentSize: commands.currentFontSize,
          isMixed: commands.isFontSizeMixed
        ) {
          _ = commands.applyFontSize(size)
        }
      }
      fontSizeText = fontSizeDisplay
    }

    private func colorAccessibilityValue(
      color: NSColor?,
      isMixed: Bool,
      emptyName: String
    ) -> String {
      guard !isMixed else { return "Mixed" }
      guard let color else { return emptyName }
      return FleckPaletteOption.paletteName(for: color) ?? "Custom"
    }

    private func formattingStateValue(isOn: Bool, isMixed: Bool) -> String {
      isMixed ? "Mixed" : isOn ? "On" : "Off"
    }
  }

  private struct EditorFindShortcutRouter: NSViewRepresentable {
    let commands: EditorCommands

    func makeNSView(context: Context) -> EditorFindShortcutRoutingView {
      EditorFindShortcutRoutingView(commands: commands)
    }

    func updateNSView(_ view: EditorFindShortcutRoutingView, context: Context) {
      view.commands = commands
    }
  }

  private final class EditorFindShortcutRoutingView: NSView {
    var commands: EditorCommands

    init(commands: EditorCommands) {
      self.commands = commands
      super.init(frame: .zero)
      setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
      nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard event.type == .keyDown,
        let key = event.charactersIgnoringModifiers?.lowercased()
      else { return super.performKeyEquivalent(with: event) }
      let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
      let action: EditorFindAction
      if key == "f", modifiers == [.command, .option] {
        action = .showFind
      } else if key == "f", modifiers == [.command, .option, .shift] {
        action = .showReplace
      } else if key == "g", modifiers == [.command] {
        action = .nextMatch
      } else if key == "g", modifiers == [.command, .shift] {
        action = .previousMatch
      } else {
        return super.performKeyEquivalent(with: event)
      }
      return commands.performFind(action)
    }
  }

  private struct PinnedNavigationChromeSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.fleckChromeAppearance) private var appearance
    @Environment(\.fleckThemeSnapshot) private var theme

    func body(content: Content) -> some View {
      switch materialPolicy {
      case .liquidGlass:
        if #available(macOS 26, *) {
          content.background {
            Rectangle()
              .fill(.clear)
              .glassEffect(.regular, in: Rectangle())
              .allowsHitTesting(false)
          }
        } else {
          content.background(.ultraThinMaterial)
        }
      case .legacyMaterial:
        content.background(.ultraThinMaterial)
      case .opaque:
        let solidChrome = NotesSolidChrome(theme: theme, appearance: appearance)
        content.background(theme.color(solidChrome.isActive ? .editorOpaque : .window))
      }
    }

    private var materialPolicy: FleckChromeMaterialPolicy {
      FleckChromeMaterialPolicy.current(
        appearance: appearance,
        reduceTransparency: reduceTransparency,
        increasedContrast: colorSchemeContrast == .increased
      )
    }
  }

  private struct FormattingBarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.fleckChromeAppearance) private var appearance
    @Environment(\.fleckThemeSnapshot) private var theme

    let isPinned: Bool

    func body(content: Content) -> some View {
      let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
      switch materialPolicy {
      case .liquidGlass:
        if isPinned {
          if #available(macOS 26, *) {
            content.glassEffect(
              Glass.regular.tint(theme.color(.accent).opacity(0.08)),
              in: shape
            )
          } else {
            content
              .background {
                shape.fill(.ultraThinMaterial)
              }
          }
        } else {
          content
        }
      case .legacyMaterial:
        if isPinned {
          content.background { shape.fill(.ultraThinMaterial) }
        } else {
          content
        }
      case .opaque:
        let solidChrome = NotesSolidChrome(theme: theme, appearance: appearance)
        if solidChrome.isActive {
          let compactShape = RoundedRectangle(cornerRadius: 8, style: .circular)
          content.background {
            compactShape.fill(solidChrome.toolbarSurface)
              .overlay { compactShape.strokeBorder(solidChrome.toolbarOutline, lineWidth: 1) }
          }
        } else {
          content.background { shape.fill(theme.color(.card)) }
        }
      }
    }

    private var materialPolicy: FleckChromeMaterialPolicy {
      FleckChromeMaterialPolicy.current(
        appearance: appearance,
        reduceTransparency: reduceTransparency,
        increasedContrast: colorSchemeContrast == .increased
      )
    }
  }

  private struct PinnedWritingSurface: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> AdaptiveOpaqueSurfaceView {
      AdaptiveOpaqueSurfaceView(color: color)
    }

    func updateNSView(_ nsView: AdaptiveOpaqueSurfaceView, context: Context) {
      nsView.updateSurfaceColor(color)
    }
  }

  final class AdaptiveOpaqueSurfaceView: NSView {
    private var surfaceColor: NSColor
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(color: NSColor = .textBackgroundColor) {
      surfaceColor = color
      super.init(frame: .zero)
      identifier = NSUserInterfaceItemIdentifier("pinnedWritingSurface")
      wantsLayer = true
      updateSurfaceColor(color)
    }

    override init(frame frameRect: NSRect) {
      surfaceColor = .textBackgroundColor
      super.init(frame: frameRect)
      identifier = NSUserInterfaceItemIdentifier("pinnedWritingSurface")
      wantsLayer = true
      updateSurfaceColor()
    }

    required init?(coder: NSCoder) {
      surfaceColor = .textBackgroundColor
      super.init(coder: coder)
      identifier = NSUserInterfaceItemIdentifier("pinnedWritingSurface")
      wantsLayer = true
      updateSurfaceColor()
    }

    override func updateLayer() {
      updateSurfaceColor()
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }

    func updateSurfaceColor() {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        layer?.backgroundColor = surfaceColor.cgColor
      }
    }

    func updateSurfaceColor(_ color: NSColor) {
      surfaceColor = color
      updateSurfaceColor()
    }
  }

  private struct SolidOverflowSizeDraft<Content: View>: View {
    @State private var draft: String? = nil
    @ViewBuilder let content: (Binding<String?>) -> Content

    var body: some View { content($draft) }
  }

  private struct CrispToolbarButtonStyle: ButtonStyle {
    let motion: AppMotion

    func makeBody(configuration: Configuration) -> some View {
      CrispToolbarButtonBody(configuration: configuration, motion: motion)
    }
  }

  private struct CrispToolbarButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let motion: AppMotion

    var body: some View {
      configuration.label
        .background(
          isEnabled && isHovered ? Color.primary.opacity(0.10) : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .scaleEffect(configuration.isPressed ? motion.pressScale : 1)
        .animation(motion.quick, value: configuration.isPressed)
        .onHover { isHovered = $0 }
    }
  }

  // Frames never follow presentation offsets: every slot is measured from the
  // original row, so reversing direction cannot chase an animated hit region.
  struct FluidTabReorder: Equatable {
    var interaction: ReorderInteraction
    let frames: [UUID: CGRect]
    let grabOffset: CGFloat
    let spacing: CGFloat = 6
    private(set) var destination: Int

    init?(interaction: ReorderInteraction, frames: [UUID: CGRect], pointerX: CGFloat) {
      guard let source = frames[interaction.sourceID], source.width > 0,
        interaction.originalIDs.allSatisfy({ frames[$0] != nil }),
        let index = interaction.originalIDs.firstIndex(of: interaction.sourceID)
      else { return nil }
      self.interaction = interaction
      self.frames = frames
      grabOffset = pointerX - source.minX
      destination = index
    }

    private var remaining: [UUID] { interaction.originalIDs.filter { $0 != interaction.sourceID } }
    private var sourceFrame: CGRect { frames[interaction.sourceID]! }
    private func slotX(_ index: Int) -> CGFloat {
      frames[interaction.originalIDs[0]]!.minX
        + remaining.prefix(index).reduce(0) { $0 + frames[$1]!.width + spacing }
    }
    var slotFrame: CGRect {
      CGRect(x: slotX(destination), y: sourceFrame.minY, width: sourceFrame.width, height: sourceFrame.height)
    }
    mutating func update(pointerX: CGFloat) {
      let pinned = interaction.pinnedIDs.contains(interaction.sourceID)
      let pinnedCount = remaining.filter { interaction.pinnedIDs.contains($0) }.count
      let allowed = pinned ? 0...pinnedCount : pinnedCount...remaining.count
      let left = pointerX - grabOffset
      destination = allowed.min { abs(slotX($0) - left) < abs(slotX($1) - left) }!
      interaction.clearTarget()
      if destination < remaining.count,
        interaction.pinnedIDs.contains(remaining[destination]) == pinned {
        interaction.propose(over: remaining[destination], after: false, currentIDs: interaction.originalIDs)
      } else if destination > 0, interaction.pinnedIDs.contains(remaining[destination - 1]) == pinned {
        interaction.propose(over: remaining[destination - 1], after: true, currentIDs: interaction.originalIDs)
      }
    }
    func offset(for id: UUID) -> CGFloat {
      guard id != interaction.sourceID, let original = frames[id], let index = remaining.firstIndex(of: id)
      else { return 0 }
      let newX = slotX(index) + (index >= destination ? sourceFrame.width + spacing : 0)
      return newX - original.minX
    }
    func isValid(ids: [UUID], pins: Set<UUID>, frames liveFrames: [UUID: CGRect],
      backingScaleFactor: CGFloat = 1) -> Bool {
      let backingPixel = 1 / max(1, backingScaleFactor)
      return ids == interaction.originalIDs && pins == interaction.pinnedIDs
        && ids.allSatisfy { id in
          guard let frozen = frames[id]?.size, let live = liveFrames[id]?.size else { return false }
          return abs(frozen.width - live.width) <= backingPixel
            && abs(frozen.height - live.height) <= backingPixel
        }
    }
    static func scrollDelta(pointerX: CGFloat, viewport: ClosedRange<CGFloat>) -> CGFloat {
      guard viewport.contains(pointerX) else { return 0 }
      let edge: CGFloat = min(32, (viewport.upperBound - viewport.lowerBound) / 3)
      if pointerX < viewport.lowerBound + edge { return -10 * (1 - (pointerX - viewport.lowerBound) / edge) }
      if pointerX > viewport.upperBound - edge { return 10 * (1 - (viewport.upperBound - pointerX) / edge) }
      return 0
    }
  }

  @MainActor final class FluidTabDragController: ObservableObject {
    @Published private(set) var preview: FluidTabReorder?
    @Published private(set) var inside = false
    private(set) var animatesDisplacement = true
    weak var view: FluidTabDestinationView?
    private var session: ReorderDropSession?
    private var currentIDs: (() -> [UUID])?
    private var currentPins: (() -> Set<UUID>)?
    private var move: ((UUID, Int) -> Void)?
    private var finish: (() -> Void)?
    private var timer: Timer?
    private var nativePoint: NSPoint?
    private var viewportSize: NSSize?
    private var accepted = false
    private weak var sourceView: ReorderSourceHostingView?

    private var pendingInteraction: ReorderInteraction?

    func prepare(interaction: ReorderInteraction, session: ReorderDropSession,
      currentIDs: @escaping () -> [UUID], currentPins: @escaping () -> Set<UUID>,
      move: @escaping (UUID, Int) -> Void, finish: @escaping () -> Void) {
      cancel()
      pendingInteraction = interaction
      self.session = session
      self.currentIDs = currentIDs
      self.currentPins = currentPins
      self.move = move
      self.finish = finish
    }

    // Native dragging items already contain the visible tab snapshot here.
    func began(at pointer: NSPoint) {
      guard let interaction = pendingInteraction, let view, let window = view.window else { return }
      let localPointer = view.convert(window.convertPoint(fromScreen: pointer), from: nil)
      let frames = view.sourceFrames()
      guard let initial = FluidTabReorder(interaction: interaction, frames: frames, pointerX: localPointer.x)
      else { cancel(); return }
      guard let sourceView = view.sourceView(for: interaction.sourceID) else { cancel(); return }
      viewportSize = view.enclosingScrollView?.contentView.bounds.size
      preview = initial
      self.sourceView = sourceView
      setInside(true)
      nativePoint = pointer
    }

    private var valid: Bool {
      guard let preview, let currentIDs, let currentPins else { return false }
      return preview.isValid(ids: currentIDs(), pins: currentPins(), frames: view?.sourceFrames() ?? [:],
        backingScaleFactor: view?.window?.backingScaleFactor ?? 1)
        && viewportSize == view?.enclosingScrollView?.contentView.bounds.size
    }

    func moved(to point: NSPoint) {
      nativePoint = point
      guard !accepted, preview != nil else { return }
      guard valid else {
        cancel()
        return
      }
      guard let view, let window = view.window,
        let clip = view.enclosingScrollView?.contentView else { return }
      let windowPoint = window.convertPoint(fromScreen: point)
      let nextInside = clip.bounds.contains(clip.convert(windowPoint, from: nil))
      setInside(nextInside)
      if nextInside {
        var next = preview
        next?.update(pointerX: view.convert(windowPoint, from: nil).x)
        if preview != next { preview = next }
        startTimer()
      } else {
        stopTimer()
      }
    }

    func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard let view, let window = view.window else { return [] }
      moved(to: window.convertPoint(toScreen: sender.draggingLocation))
      let isValid = valid
      let canAccept = session?.canAcceptDrop == true
      let sourcePresent = sender.draggingSource != nil
      let payloadPresent = sender.draggingPasteboard.availableType(
        from: [.init(FolderDragPayload.noteType.identifier)]
      ) != nil
      return isValid && inside && canAccept && sourcePresent && payloadPresent ? .move : []
    }

    func exited() {
      setInside(false)
      stopTimer()
    }

    func perform(_ sender: any NSDraggingInfo) -> Bool {
      let requestedOperation = operation(sender)
      let data = sender.draggingPasteboard.data(
        forType: .init(FolderDragPayload.noteType.identifier)
      )
      guard requestedOperation == .move, let preview, let session, let currentIDs,
        let currentPins, let move,
        let data
      else { return false }
      let didAccept: Bool
      if preview.destination == preview.interaction.originalIDs.firstIndex(of: preview.interaction.sourceID) {
        didAccept = session.acceptDrop(data: data, commit: {})
      } else {
        didAccept = session.acceptReorder(data: data, interaction: preview.interaction,
          currentIDs: currentIDs, currentPinnedIDs: currentPins, move: move)
      }
      guard didAccept else { return false }
      accepted = true
      stopTimer()
      return true
    }

    func ended(sessionID: UUID, operation: NSDragOperation) {
      guard session?.id == sessionID else { return }
      stopTimer()
      reset(animated: !(accepted && operation == .move))
    }
    func cancel() {
      session?.cancel()
      reset()
    }
    private func reset(animated: Bool = true) {
      stopTimer()
      sourceView?.closeNativePreview()
      sourceView?.setDraggingSourceHidden(false)
      sourceView = nil
      animatesDisplacement = animated
      let finish = finish
      self.finish = nil
      currentIDs = nil
      currentPins = nil
      move = nil
      viewportSize = nil
      session = nil
      pendingInteraction = nil
      preview = nil
      inside = false
      accepted = false
      nativePoint = nil
      finish?()
    }
    private func setInside(_ value: Bool) {
      guard inside != value else { return }
      inside = value
      sourceView?.setDraggingSourceHidden(value)
    }
    private func startTimer() {
      guard timer == nil else { return }
      let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
      RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    func tick() {
      guard inside, !accepted, valid, let nativePoint, let view, let window = view.window,
        let scroll = view.enclosingScrollView, let document = scroll.documentView else {
        if !valid {
          cancel()
        } else {
          stopTimer()
        }
        return
      }
      let clip = scroll.contentView
      let point = clip.convert(window.convertPoint(fromScreen: nativePoint), from: nil)
      guard clip.bounds.contains(point) else { exited(); return }
      let delta = FluidTabReorder.scrollDelta(pointerX: point.x, viewport: clip.bounds.minX...clip.bounds.maxX)
      if delta != 0 {
        let x = min(max(clip.bounds.minX + delta, 0), max(0, document.bounds.width - clip.bounds.width))
        // Constraining an NSClipView can leave floating-point rounding residue at an edge.
        // Treat only that numerical noise as unchanged while preserving real subpixel scrolling.
        let coordinateMagnitude = max(1, abs(x), abs(clip.bounds.minX))
        let noiseTolerance = CGFloat.ulpOfOne.squareRoot() * coordinateMagnitude
        guard abs(x - clip.bounds.minX) > noiseTolerance else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        var next = preview
        next?.update(pointerX: view.convert(window.convertPoint(fromScreen: nativePoint), from: nil).x)
        if preview != next { preview = next }
      }
    }
  }

  private struct FluidTabStripHost<Content: View>: NSViewRepresentable {
    @ObservedObject var controller: FluidTabDragController
    let selectedID: UUID?
    let selectedColor: Color?
    let hoverColor: Color?
    let reduceMotion: Bool
    let capsuleOutset: CGFloat
    let content: Content
    init(controller: FluidTabDragController, selectedID: UUID?, selectedColor: Color?, hoverColor: Color?,
      reduceMotion: Bool, capsuleOutset: CGFloat, @ViewBuilder content: () -> Content) {
      self.controller = controller
      self.selectedID = selectedID
      self.selectedColor = selectedColor
      self.hoverColor = hoverColor
      self.reduceMotion = reduceMotion
      self.capsuleOutset = capsuleOutset
      self.content = content()
    }
    func makeNSView(context: Context) -> FluidTabDestinationView {
      let view = FluidTabDestinationView(rootView: AnyView(EmptyView()))
      view.sizingOptions = [.intrinsicContentSize]
      view.registerForDraggedTypes([.init(FolderDragPayload.noteType.identifier)])
      view.controller = controller
      controller.view = view
      return view
    }
    func updateNSView(_ view: FluidTabDestinationView, context: Context) {
      view.rootView = AnyView(content.environment(\.self, context.environment))
      view.updateSelection(
        noteID: selectedID,
        color: selectedColor.flatMap {
          NSColor(cgColor: $0.resolve(in: context.environment).cgColor)
        },
        reduceMotion: reduceMotion,
        capsuleOutset: capsuleOutset
      )
      view.updateHoverColor(hoverColor.map { $0.resolve(in: context.environment).cgColor })
    }
  }

  final class FluidTabDestinationView: NSHostingView<AnyView> {
    weak var controller: FluidTabDragController?
    let selectionHighlightLayer = CALayer()
    private var selectedID: UUID?
    private var selectedColor: NSColor?
    private var selectionTargetFrame: CGRect?
    private var reduceMotion = false
    private var capsuleOutset: CGFloat = 0
    let hoverHighlightLayer = CALayer()
    private weak var hoveredSource: ReorderSourceHostingView?
    private var hoverMonitor: Any?
    private var hoverExitArea: NSTrackingArea?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow !== window { stopHoverTracking() }
      super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      startHoverTrackingIfNeeded()
    }

    func updateHoverColor(_ color: CGColor?) {
      if color != nil, hoverHighlightLayer.superlayer == nil {
        hoverHighlightLayer.zPosition = -1
        layer?.insertSublayer(hoverHighlightLayer, at: 0)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      hoverHighlightLayer.backgroundColor = color
      CATransaction.commit()
      if color == nil { stopHoverTracking() } else { startHoverTrackingIfNeeded() }
      syncHoverFrame()
    }

    private func startHoverTrackingIfNeeded() {
      guard let window, hoverHighlightLayer.backgroundColor != nil else { return }
      window.acceptsMouseMovedEvents = true
      guard hoverMonitor == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
        owner: self, userInfo: nil
      )
      addTrackingArea(area)
      hoverExitArea = area
      hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
        [weak self] event in
        self?.updateHover(for: event)
        return event
      }
    }

    private func stopHoverTracking() {
      if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
      hoverMonitor = nil
      if let hoverExitArea { removeTrackingArea(hoverExitArea) }
      hoverExitArea = nil
      setHoveredSource(nil)
    }

    override func mouseEntered(with event: NSEvent) {
      if let hoverExitArea, event.trackingArea === hoverExitArea {
        updateHover(for: event)
      } else {
        super.mouseEntered(with: event)
      }
    }

    override func mouseExited(with event: NSEvent) {
      if let hoverExitArea, event.trackingArea === hoverExitArea {
        setHoveredSource(nil)
      } else {
        super.mouseExited(with: event)
      }
    }

    private func updateHover(for event: NSEvent) {
      guard event.type != .leftMouseDragged, let window, window.isVisible, event.window === window,
        let superview, visibleRect.contains(convert(event.locationInWindow, from: nil)),
        let hit = hitTest(superview.convert(event.locationInWindow, from: nil)) else {
        setHoveredSource(nil)
        return
      }
      let source = sequence(first: hit as NSView?, next: { $0?.superview })
        .compactMap { $0 as? ReorderSourceHostingView }.first
      setHoveredSource(source)
    }

    private func setHoveredSource(_ source: ReorderSourceHostingView?) {
      guard hoveredSource !== source || (source == nil && !hoverHighlightLayer.isHidden) else { return }
      hoveredSource = source
      syncHoverFrame()
    }

    private func syncHoverFrame() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      guard hoverHighlightLayer.backgroundColor != nil, let source = hoveredSource,
        let window, let noteID = source.noteID, noteID != selectedID, source.window === window,
        source.layer?.opacity != 0 else {
        hoverHighlightLayer.isHidden = true
        return
      }
      let target = convert(
        source.labelCapsuleRect.insetBy(dx: -capsuleOutset, dy: -capsuleOutset), from: source
      )
      hoverHighlightLayer.frame = target
      hoverHighlightLayer.cornerRadius = target.height / 2
      hoverHighlightLayer.isHidden = false
    }

    func updateSelection(noteID: UUID?, color: NSColor?, reduceMotion: Bool, capsuleOutset: CGFloat = 0) {
      wantsLayer = true
      if selectionHighlightLayer.superlayer == nil {
        selectionHighlightLayer.isHidden = true
        selectionHighlightLayer.zPosition = -1
        layer?.insertSublayer(selectionHighlightLayer, at: 0)
      }
      let changed = selectedID != noteID
      let hadVisibleSelection = !selectionHighlightLayer.isHidden
        && selectionHighlightLayer.opacity != 0 && selectionTargetFrame != nil
      selectedID = noteID
      selectedColor = color
      self.reduceMotion = reduceMotion
      self.capsuleOutset = capsuleOutset
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      selectionHighlightLayer.backgroundColor = color?.cgColor
      CATransaction.commit()
      if reduceMotion {
        selectionHighlightLayer.removeAnimation(forKey: "fleck.tab-selection")
      }
      syncSelectionFrame(animated: changed && hadVisibleSelection && !reduceMotion)
    }

    override func layout() {
      super.layout()
      syncSelectionFrame(animated: false)
      syncHoverFrame()
    }

    func selectionSourcePresentationDidChange(_ source: ReorderSourceHostingView, animated: Bool) {
      guard source.noteID == selectedID else { return }
      syncSelectionFrame(animated: animated && !reduceMotion)
    }

    func selectedCapsuleColor(for source: ReorderSourceHostingView) -> NSColor? {
      source.noteID == selectedID ? selectedColor : nil
    }

    private func syncSelectionFrame(animated: Bool) {
      guard let selectedID, selectedColor != nil, let source = sourceView(for: selectedID) else {
        selectionHighlightLayer.removeAnimation(forKey: "fleck.tab-selection")
        selectionTargetFrame = nil
        selectionHighlightLayer.isHidden = true
        return
      }
      var target = convert(source.labelCapsuleRect.insetBy(dx: -capsuleOutset, dy: -capsuleOutset), from: source)
      target.origin.x += source.layer?.transform.m41 ?? 0
      let hidden = source.layer?.opacity == 0
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      selectionHighlightLayer.isHidden = false
      selectionHighlightLayer.opacity = hidden ? 0 : 1
      CATransaction.commit()
      guard target != selectionTargetFrame else { return }
      let fromPosition = selectionHighlightLayer.presentation()?.position ?? selectionHighlightLayer.position
      let fromBounds = selectionHighlightLayer.presentation()?.bounds ?? selectionHighlightLayer.bounds
      selectionTargetFrame = target
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      selectionHighlightLayer.position = CGPoint(x: target.midX, y: target.midY)
      selectionHighlightLayer.bounds = CGRect(origin: .zero, size: target.size)
      selectionHighlightLayer.cornerRadius = target.height / 2
      selectionHighlightLayer.removeAnimation(forKey: "fleck.tab-selection")
      if animated {
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = fromPosition
        position.toValue = selectionHighlightLayer.position
        position.duration = AppMotion.selectionDuration
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = fromBounds
        bounds.toValue = selectionHighlightLayer.bounds
        bounds.duration = AppMotion.selectionDuration
        let group = CAAnimationGroup()
        group.animations = [position, bounds]
        group.duration = AppMotion.selectionDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.beginTime = CACurrentMediaTime()
        selectionHighlightLayer.add(group, forKey: "fleck.tab-selection")
      }
      CATransaction.commit()
    }

    func sourceFrames() -> [UUID: CGRect] {
      var frames: [UUID: CGRect] = [:]
      func collect(_ view: NSView) {
        if let source = view as? ReorderSourceHostingView, let noteID = source.noteID {
          frames[noteID] = convert(source.bounds, from: source)
          return
        }
        for child in view.subviews { collect(child) }
      }
      collect(self)
      return frames
    }

    func sourceView(for noteID: UUID) -> ReorderSourceHostingView? {
      func find(_ view: NSView) -> ReorderSourceHostingView? {
        if let source = view as? ReorderSourceHostingView, source.noteID == noteID {
          return source
        }
        return view.subviews.lazy.compactMap(find).first
      }
      return find(self)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
      controller?.operation(sender) ?? []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
      controller?.operation(sender) ?? []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
      controller?.exited()
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      let prepared = controller?.operation(sender) == .move
      guard prepared else { return false }
      sender.animatesToDestination = false
      return true
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      controller?.perform(sender) ?? false
    }
  }

  private struct ReorderDropTarget: ViewModifier {
    let destinationID: UUID
    let type: UTType
    @Binding var interaction: ReorderInteraction?
    @Binding var session: ReorderDropSession?
    let currentIDs: () -> [UUID]
    let currentPinnedIDs: () -> Set<UUID>
    let accepts: () -> Bool
    let finish: () -> Void
    let move: (UUID, Int) -> Void
    var noteDrop: (any DropDelegate)? = nil
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleckThemeSnapshot) private var theme

    func body(content: Content) -> some View {
      content
        .padding(.leading, interaction?.targetID == destinationID && interaction?.after == false ? 3 : 0)
        .padding(.trailing, interaction?.targetID == destinationID && interaction?.after == true ? 3 : 0)
        .animation(AppMotion(reduceMotion: reduceMotion).spatial, value: interaction)
        .background(GeometryReader { geometry in
          Color.clear.onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { _, value in width = value }
        })
        .overlay(alignment: interaction?.after == true ? .trailing : .leading) {
          if interaction?.targetID == destinationID {
            Capsule().fill(theme.color(.accent)).frame(width: 2, height: 22)
              .offset(x: interaction?.after == true ? 3 : -3)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .onDrop(of: noteDrop == nil ? [type] : [type, FolderDragPayload.noteType], delegate: TabDropDelegate(
          destinationID: destinationID, width: width, type: type,
          interaction: $interaction, session: $session, currentIDs: currentIDs,
          currentPinnedIDs: currentPinnedIDs,
          accepts: accepts, finish: finish, move: move, noteDrop: noteDrop
        ))
    }
  }

  private struct TabDropDelegate: DropDelegate {
    let destinationID: UUID
    let width: CGFloat
    let type: UTType
    @Binding var interaction: ReorderInteraction?
    @Binding var session: ReorderDropSession?
    let currentIDs: () -> [UUID]
    let currentPinnedIDs: () -> Set<UUID>
    let accepts: () -> Bool
    let finish: () -> Void
    let move: (UUID, Int) -> Void
    var noteDrop: (any DropDelegate)? = nil

    private var activeNoteDrop: (any DropDelegate)? {
      session?.type == FolderDragPayload.noteType ? noteDrop : nil
    }

    func validateDrop(info: DropInfo) -> Bool {
      if let activeNoteDrop { return activeNoteDrop.validateDrop(info: info) }
      let accepted = session?.canAcceptDrop == true && session?.id == interaction?.sessionID
        && session?.type == type
        && info.hasItemsConforming(to: [type]) && accepts()
      return interaction != nil && interaction?.sourceID != destinationID
        && accepted && interaction?.originalIDs == currentIDs()
    }

    func dropEntered(info: DropInfo) {
      if let activeNoteDrop { activeNoteDrop.dropEntered(info: info); return }
      update(info)
    }

    private func update(_ info: DropInfo) {
      guard validateDrop(info: info) else {
        interaction?.clearTarget()
        return
      }
      interaction?.propose(over: destinationID, after: info.location.x >= width / 2,
        currentIDs: currentIDs())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
      if let activeNoteDrop { return activeNoteDrop.dropUpdated(info: info) }
      update(info)
      return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
      if let activeNoteDrop { activeNoteDrop.dropExited(info: info); return }
      if interaction?.targetID == destinationID { interaction?.clearTarget() }
    }

    func performDrop(info: DropInfo) -> Bool {
      if let activeNoteDrop { return activeNoteDrop.performDrop(info: info) }
      update(info)
      guard validateDrop(info: info), let proposal = interaction, let session,
        session.acceptReorder(from: info.itemProviders(for: [type]), interaction: proposal,
          currentIDs: currentIDs, currentPinnedIDs: currentPinnedIDs, move: move) != nil
      else { return false }
      interaction = nil
      finish()
      return true
    }
  }

  // Folders keep SwiftUI's drag source. Note tabs own their left-pointer gesture
  // so AppKit receives the real threshold event and a snapshot captured before hiding.
  private struct ReorderDragSource: ViewModifier {
    let begin: () -> (NSItemProvider, NSPasteboardWriting?, (NSDragOperation) -> Void)
    var began: ((NSPoint) -> Void)? = nil
    var moved: ((NSPoint) -> Void)? = nil
    var activate: (() -> Void)? = nil
    var noteID: UUID? = nil
    var displacement: CGFloat? = nil
    var animatesDisplacement = false

    func body(content: Content) -> some View {
      let host = ReorderDragHost(content: content, begin: begin, began: began, moved: moved,
        activate: activate, noteID: noteID, displacement: displacement,
        animatesDisplacement: animatesDisplacement)
      if noteID != nil {
        host.accessibilityRepresentation { content }
      } else {
        host
      }
    }
  }

  private struct ReorderDragHost<Content: View>: NSViewRepresentable {
    let content: Content
    let begin: () -> (NSItemProvider, NSPasteboardWriting?, (NSDragOperation) -> Void)
    let began: ((NSPoint) -> Void)?
    let moved: ((NSPoint) -> Void)?
    let activate: (() -> Void)?
    let noteID: UUID?
    let displacement: CGFloat?
    let animatesDisplacement: Bool

    func makeNSView(context: Context) -> ReorderSourceHostingView {
      let view = ReorderSourceHostingView(rootView: AnyView(EmptyView()))
      view.sizingOptions = [.intrinsicContentSize]
      return view
    }

    func updateNSView(_ view: ReorderSourceHostingView, context: Context) {
      view.noteID = noteID
      view.onBegan = began
      view.onMoved = moved
      view.onNativeBegin = noteID == nil ? nil : begin
      view.onPrimaryClick = noteID == nil ? nil : activate
      let dragContent = content.environment(\.self, context.environment)
      if noteID == nil {
        view.rootView = AnyView(
          dragContent.onDrag({ [weak view] in
            let (provider, _, end) = begin()
            view?.onEnd = end
            return provider
          }, preview: {
            dragContent
          })
        )
      } else {
        view.rootView = AnyView(dragContent)
      }
      if let displacement { view.setReorderDisplacement(displacement, animated: animatesDisplacement) }
    }
  }

  final class ReorderSourceHostingView: NSHostingView<AnyView> {
    var noteID: UUID?

    var labelCapsuleRect: CGRect {
      let fitting = fittingSize
      guard fitting.width > 0, fitting.height > 0 else { return bounds }
      let size = CGSize(width: min(bounds.width, fitting.width), height: min(bounds.height, fitting.height))
      return CGRect(
        x: bounds.midX - size.width / 2,
        y: bounds.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    }

    // Keep layout in its original order during hover. AppKit owns the layer
    // transition, including interruption, instead of relying on SwiftUI to
    // animate the frame of a native representable during drag tracking.
    func setReorderDisplacement(_ offset: CGFloat, animated: Bool) {
      wantsLayer = true
      guard let layer else { return }
      let key = "fleck.tab-reorder"
      if layer.transform.m41 == offset && animated { return }
      let from = layer.presentation()?.transform.m41 ?? layer.transform.m41
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      var transform = layer.transform
      transform.m41 = offset
      layer.transform = transform
      layer.removeAnimation(forKey: key)
      if animated && abs(from - offset) > 0.01 {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = from
        animation.toValue = offset
        animation.duration = AppMotion.standardDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
      }
      CATransaction.commit()
      tabDestination?.selectionSourcePresentationDidChange(self, animated: animated)
    }

    func setDraggingSourceHidden(_ hidden: Bool) {
      wantsLayer = true
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.opacity = hidden ? 0 : 1
      CATransaction.commit()
      tabDestination?.selectionSourcePresentationDidChange(self, animated: false)
    }

    private var tabDestination: FluidTabDestinationView? {
      sequence(first: superview, next: { $0?.superview })
        .compactMap { $0 as? FluidTabDestinationView }.first
    }

    var onEnd: ((NSDragOperation) -> Void)?
    var onBegan: ((NSPoint) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var onNativeBegin: (() -> (NSItemProvider, NSPasteboardWriting?, (NSDragOperation) -> Void))?
    var onPrimaryClick: (() -> Void)?
    #if DEBUG
      var interceptNativeDrag: (([NSDraggingItem], ReorderNativeSource, NSEvent) -> Bool)?
    #endif
    private var pointerDown: (event: NSEvent, point: NSPoint)?
    private var sourceProxy: ReorderNativeSource?

    override func mouseDown(with event: NSEvent) {
      guard noteID != nil, !event.modifierFlags.contains(.control) else {
        pointerDown = nil
        super.mouseDown(with: event)
        return
      }
      pointerDown = (event, convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
      guard noteID != nil else {
        super.mouseDragged(with: event)
        return
      }
      guard let press = pointerDown, sourceProxy == nil else { return }
      let point = convert(event.locationInWindow, from: nil)
      let distance = NSPoint(x: point.x - press.point.x, y: point.y - press.point.y)
      guard distance.x * distance.x + distance.y * distance.y >= 16,
        let onNativeBegin
      else { return }
      pointerDown = nil
      let image = draggingImage()
      guard let preview = ReorderNativePreview(
        image: image, sourceView: self, grabPoint: press.point
      ) else { return }
      let (_, pasteboardWriter, end) = onNativeBegin()
      guard let pasteboardWriter else {
        preview.close()
        end([])
        return
      }
      let item = NSDraggingItem(pasteboardWriter: pasteboardWriter)
      item.setDraggingFrame(bounds, contents: nil)
      let id = UUID()
      let proxy = ReorderNativeSource(
        id: id, source: nil, began: onBegan, preview: preview
      ) { [weak self] operation in
        end(operation)
        if self?.sourceProxy?.id == id { self?.sourceProxy = nil }
      }
      proxy.moved = onMoved
      sourceProxy = proxy
      #if DEBUG
        if interceptNativeDrag?([item], proxy, press.event) == true {
          proxy.end([])
          return
        }
      #endif
      let session = super.beginDraggingSession(with: [item], event: press.event, source: proxy)
      session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
      guard noteID != nil else {
        super.mouseUp(with: event)
        return
      }
      guard pointerDown != nil else { return }
      pointerDown = nil
      let point = convert(event.locationInWindow, from: nil)
      if bounds.contains(point) { onPrimaryClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
      pointerDown = nil
      super.rightMouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { sourceProxy?.closePreview() }
    }

    private func draggingImage() -> NSImage {
      var image = NSImage(size: bounds.size)
      effectiveAppearance.performAsCurrentDrawingAppearance {
        guard let captured = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: captured)
        image = Self.compositedDraggingImage(
          captured: captured, size: bounds.size, appearance: effectiveAppearance,
          selectedCapsuleColor: tabDestination?.selectedCapsuleColor(for: self),
          selectedCapsuleRect: labelCapsuleRect
        ) ?? image
      }
      return image
    }

    static func compositedDraggingImage(captured: NSBitmapImageRep, size: NSSize,
      appearance: NSAppearance, selectedCapsuleColor: NSColor? = nil,
      selectedCapsuleRect: NSRect? = nil) -> NSImage? {
      let image = NSImage(size: size)
      guard let selectedCapsuleColor else {
        image.addRepresentation(captured)
        return image
      }
      guard let representation = captured.copy() as? NSBitmapImageRep else { return nil }
      representation.size = size
      guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
      appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        context.compositingOperation = .destinationOver
        selectedCapsuleColor.setFill()
        let capsule = selectedCapsuleRect ?? rect
        NSBezierPath(
          roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
      }
      image.addRepresentation(representation)
      return image
    }

    func closeNativePreview() {
      sourceProxy?.closePreview()
    }

    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent,
      source: any NSDraggingSource) -> NSDraggingSession {
      let id = UUID()
      let began = onBegan
      let end = onEnd
      onEnd = nil
      let proxy = ReorderNativeSource(id: id, source: source, began: began) { [weak self] operation in
        end?(operation)
        if self?.sourceProxy?.id == id { self?.sourceProxy = nil }
      }
      proxy.moved = onMoved
      sourceProxy = proxy
      let session = super.beginDraggingSession(with: items, event: event, source: proxy)
      if began != nil {
        session.animatesToStartingPositionsOnCancelOrFail = false
      }
      return session
    }
  }

  @MainActor final class ReorderNativePreview {
    let image: NSImage
    let panel: NSPanel
    private let initialFrame: NSRect
    private let grabOffset: NSPoint
    private var isClosed = false

    init?(image: NSImage, sourceView: NSView, grabPoint: NSPoint) {
      guard let sourceWindow = sourceView.window else { return nil }
      self.image = image
      initialFrame = sourceWindow.convertToScreen(sourceView.convert(sourceView.bounds, to: nil))
      let grabPointOnScreen = sourceWindow.convertPoint(
        toScreen: sourceView.convert(grabPoint, to: nil)
      )
      grabOffset = NSPoint(
        x: grabPointOnScreen.x - initialFrame.minX,
        y: grabPointOnScreen.y - initialFrame.minY
      )
      panel = NSPanel(
        contentRect: initialFrame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.isReleasedWhenClosed = false
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.hidesOnDeactivate = false
      panel.level = NSWindow.Level(rawValue: sourceWindow.level.rawValue + 1)
      let imageView = NSImageView(frame: NSRect(origin: .zero, size: initialFrame.size))
      imageView.image = image
      imageView.imageScaling = .scaleNone
      panel.contentView = imageView
    }

    func show(at point: NSPoint) {
      guard !isClosed else { return }
      panel.setFrameOrigin(NSPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y))
      panel.orderFrontRegardless()
    }

    func move(to point: NSPoint) {
      guard !isClosed else { return }
      panel.setFrameOrigin(NSPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y))
    }

    func close() {
      guard !isClosed else { return }
      isClosed = true
      panel.orderOut(nil)
      panel.close()
    }

    deinit {
      MainActor.assumeIsolated {
        panel.orderOut(nil)
        panel.close()
      }
    }
  }

  @MainActor final class ReorderNativeSource: NSObject, NSDraggingSource {
    let id: UUID
    let source: (any NSDraggingSource)?
    let began: ((NSPoint) -> Void)?
    private(set) var preview: ReorderNativePreview?
    private let endHandler: (NSDragOperation) -> Void
    var moved: ((NSPoint) -> Void)?

    init(id: UUID, source: (any NSDraggingSource)?, began: ((NSPoint) -> Void)?,
      preview: ReorderNativePreview? = nil, end: @escaping (NSDragOperation) -> Void) {
      self.id = id
      self.source = source
      self.began = began
      self.preview = preview
      endHandler = end
    }

    func end(_ operation: NSDragOperation) {
      closePreview()
      endHandler(operation)
    }

    func closePreview() {
      preview?.close()
    }

    func draggingSession(_ session: NSDraggingSession,
      sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      Self.operationMask(for: context)
    }

    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
      context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
      source?.ignoreModifierKeys?(for: session) ?? false
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt point: NSPoint) {
      source?.draggingSession?(session, willBeginAt: point)
      preview?.show(at: point)
      began?(point)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo point: NSPoint) {
      preview?.move(to: point)
      moved?(session.draggingLocation)
      source?.draggingSession?(session, movedTo: point)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint,
      operation: NSDragOperation) {
      source?.draggingSession?(session, endedAt: point, operation: operation)
      end(operation)
    }
  }

  // Native dragging can end outside every SwiftUI drop target. Watch its lifetime,
  // and scroll only the enclosing strip while a validated proposal is active.
  struct ReorderDragLifecycle: NSViewRepresentable {
    let active: Bool
    let hasTarget: Bool
    let cancel: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
      view.cancel = cancel
      view.hasTarget = hasTarget
      view.setActive(active)
    }
    static func dismantleNSView(_ view: DragView, coordinator: ()) { view.setActive(false) }

    final class DragView: NSView {
      var cancel: (() -> Void)?
      var hasTarget = false
      private var timer: Timer?
      private var escapeMonitor: Any?
      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func setActive(_ active: Bool) {
        guard active else {
          timer?.invalidate()
          timer = nil
          if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
          escapeMonitor = nil
          return
        }
        guard timer == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          if event.keyCode == 53 {
            self?.end()
          }
          return event
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
      }

      private func end() {
        setActive(false)
        cancel?()
      }

      private func tick() {
        guard let window else {
          end()
          return
        }
        guard hasTarget, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard clip.bounds.contains(point), let document = scroll.documentView else { return }
        let delta: CGFloat = point.x < clip.bounds.minX + 24 ? -5
          : point.x > clip.bounds.maxX - 24 ? 5 : 0
        guard delta != 0 else { return }
        let x = min(max(clip.bounds.minX + delta, 0), max(0, document.bounds.width - clip.bounds.width))
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
      }
    }
  }

  struct HighlighterMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
      let stemMinX = rect.minX + rect.width * 0.20
      let stemMaxX = rect.minX + rect.width * 0.80
      let stemTop = rect.minY + rect.height * 0.08
      let shoulderY = rect.minY + rect.height * 0.43
      let bodyBottom = rect.minY + rect.height * 0.57
      let bodyInset = rect.width * 0.08

      var path = Path()
      path.move(to: CGPoint(x: stemMinX, y: stemTop))
      path.addLine(to: CGPoint(x: stemMinX, y: shoulderY))
      path.addLine(
        to: CGPoint(x: stemMinX + bodyInset, y: bodyBottom)
      )
      path.addLine(
        to: CGPoint(x: stemMaxX - bodyInset, y: bodyBottom)
      )
      path.addLine(to: CGPoint(x: stemMaxX, y: shoulderY))
      path.addLine(to: CGPoint(x: stemMaxX, y: stemTop))
      path.move(to: CGPoint(x: stemMinX, y: shoulderY))
      path.addLine(to: CGPoint(x: stemMaxX, y: shoulderY))
      return path
    }
  }

  struct HighlighterMarkerNibShape: Shape {
    func path(in rect: CGRect) -> Path {
      let inkMinX = rect.minX + rect.width * 0.34
      let inkMaxX = rect.minX + rect.width * 0.70
      let inkTop = rect.minY + rect.height * 0.63
      let inkBottom = rect.minY + rect.height * 0.96
      let taperY = inkTop + (inkBottom - inkTop) * 0.38
      let lowerMinX = inkMinX + rect.width * 0.05

      var path = Path()
      path.move(to: CGPoint(x: inkMinX, y: inkTop))
      path.addLine(to: CGPoint(x: inkMaxX, y: inkTop))
      path.addLine(to: CGPoint(x: inkMaxX, y: taperY))
      path.addLine(to: CGPoint(x: lowerMinX, y: inkBottom))
      path.addLine(to: CGPoint(x: inkMinX, y: inkBottom))
      path.closeSubpath()
      return path
    }
  }

  struct HighlighterMarkerIcon: View {
    let inkColor: NSColor

    init(backgroundColor: NSColor?, isMixed: Bool) {
      self.inkColor = (!isMixed ? backgroundColor : nil)
        ?? FleckColorHex.nsColor(from: "#FFD600")!
    }

    var body: some View {
      ZStack {
        HighlighterMarkerNibShape()
          .fill(Color(nsColor: inkColor))
          .overlay {
            HighlighterMarkerNibShape()
              .stroke(.primary, lineWidth: 1.1)
          }
        HighlighterMarkerShape()
          .stroke(
            .primary,
            style: StrokeStyle(lineWidth: 1.15, lineCap: .butt, lineJoin: .miter)
          )
      }
        .frame(width: 20, height: 18)
        .frame(width: 28, height: 26)
        .background(.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }
  }

  private struct ToolbarIconLabel: View {
    @Environment(\.fleckChromeAppearance) private var appearance
    @Environment(\.fleckThemeSnapshot) private var theme
    let systemImage: String
    var isActive = false
    var paperGlyph: NotesPaperIcon.Glyph? = nil

    var body: some View {
      Group {
        if let paperGlyph {
          NotesPaperIcon(glyph: paperGlyph)
        } else {
          Image(systemName: systemImage)
        }
      }
      .frame(width: 28, height: NotesSolidChrome(theme: theme, appearance: appearance).isActive ? 28 : 26)
      .background(
        isActive ? theme.color(.selectionFill) : .clear,
        in: RoundedRectangle(cornerRadius: 5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 5))
    }
  }

  private struct FormattingMenuIconLabel: View {
    let systemImage: String

    var body: some View {
      HStack(spacing: 3) {
        ToolbarIconLabel(systemImage: systemImage)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
  }

  struct FormattingOverflowLabel: View {
    @Environment(\.fleckThemeSnapshot) private var theme
    @Environment(\.fleckChromeAppearance) private var appearance

    var body: some View {
      Group {
        if NotesSolidChrome(theme: theme, appearance: appearance).isActive {
          NotesPaperIcon(glyph: .overflow)
        } else {
          Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .bold))
        }
      }
      .frame(width: 28, height: NotesSolidChrome(theme: theme, appearance: appearance).isActive ? 28 : 26)
      .contentShape(RoundedRectangle(cornerRadius: 5))
    }
  }

#endif
