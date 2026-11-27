#if os(macOS)
  import AppKit
  import FleckCore
  import SwiftUI

  /// A picker never derives its editing target from the search field's focus.
  @MainActor
  final class FontPickerTarget: NSObject {
    let note: Note
    let isTitle: Bool
    let undoManager: UndoManager?
    let range: NSRange
    private let preservedFamily: String?
    private weak var textView: NSTextView?
    private var invalidated = false

    init?(note: Note, isTitle: Bool, commands: EditorCommands, preservedFamily: String? = nil) {
      guard isTitle || commands.textView != nil else { return nil }
      self.note = note
      self.isTitle = isTitle
      textView = commands.textView
      undoManager = commands.textView?.undoManager
      range = commands.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
      self.preservedFamily = preservedFamily.map(FontFamilyPickerController.normalizedFamily)
      super.init()
      if !isTitle, let storage = textView?.textStorage {
        NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: NSTextStorage.didProcessEditingNotification, object: storage)
      }
    }

    var label: String { isTitle ? "Title" : range.length == 0 ? "New text" : "Selected text" }

    @objc private func invalidate() { invalidated = true }

    func isValid(note: Note?, isEditorVisible: Bool, commands: EditorCommands) -> Bool {
      guard !invalidated, isEditorVisible, note == self.note else { return false }
      return isTitle || (textView != nil && commands.textView === textView && textView?.selectedRange() == range)
    }

    @discardableResult
    func apply(_ family: String, note: Note?, isEditorVisible: Bool, commands: EditorCommands, titleMutation: (String) -> Void) -> Bool {
      guard isValid(note: note, isEditorVisible: isEditorVisible, commands: commands) else { return false }
      invalidated = true
      if !isTitle, let textView {
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
      }
      if preservedFamily != FontFamilyPickerController.normalizedFamily(family) {
        routeFontFamilyAction(
          family: family, isTitleFocused: isTitle, titleMutation: titleMutation,
          bodyMutation: commands.applyFontFamily
        )
      }
      return true
    }
  }

  struct FontFamilyPicker: NSViewControllerRepresentable {
    let currentFamily: String?
    let isMixed: Bool
    let targetLabel: String
    var notesChrome: NotesSolidChrome?
    var onSearchChanged: (Bool) -> Void = { _ in }
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSViewController(context: Context) -> FontFamilyPickerController {
      FontFamilyPickerController(
        currentFamily: currentFamily, isMixed: isMixed, targetLabel: targetLabel,
        notesChrome: notesChrome, onSearchChanged: onSearchChanged,
        onCommit: onCommit, onCancel: onCancel
      )
    }

    func updateNSViewController(_ controller: FontFamilyPickerController, context: Context) {
      controller.onCommit = onCommit
      controller.onCancel = onCancel
      controller.onSearchChanged = onSearchChanged
    }
  }

  @MainActor
  final class FontFamilyPickerController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let searchField: NSSearchField
    private let table = FontFamilyTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching fonts")
    private let clearButton = NSButton(title: "Clear search", target: nil, action: nil)
    private static let notesSuggestions = [
      EditorTypography.systemFamily, "Avenir Next", "Georgia", "Helvetica Neue", "Times",
      "Times New Roman",
    ]
    private lazy var installedFamilies: [String] = {
      let families = NSFontManager.shared.availableFontFamilies
      guard notesChrome?.isActive == true else { return families }
      return families + Self.notesSuggestions.filter { family in
        NSFont(name: family, size: 12)?.familyName == family
      }
    }()
    private var rows: [String] = []
    private var revealsSelectionAfterLayout = false
    private let currentFamily: String?
    private let isMixed: Bool
    private let targetLabel: String
    private let notesChrome: NotesSolidChrome?
    var onSearchChanged: (Bool) -> Void
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    init(
      currentFamily: String?, isMixed: Bool, targetLabel: String,
      notesChrome: NotesSolidChrome? = nil, onSearchChanged: @escaping (Bool) -> Void = { _ in },
      onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
      self.currentFamily = currentFamily
      self.isMixed = isMixed
      self.targetLabel = targetLabel
      self.notesChrome = notesChrome
      if let notesChrome, notesChrome.isActive {
        searchField = CompactFontSearchField(increasedContrast: notesChrome.increasedContrast)
      } else {
        searchField = NSSearchField()
      }
      self.onSearchChanged = onSearchChanged
      self.onCommit = onCommit
      self.onCancel = onCancel
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func displayName(_ family: String) -> String {
      family.hasPrefix(".") ? "System" : family
    }

    static func normalizedFamily(_ family: String) -> String {
      family.hasPrefix(".") ? EditorTypography.systemFamily : family
    }

    static func families(from installed: [String], query: String) -> [String] {
      let families = [".AppleSystemUIFont"] + Set(installed.filter { !$0.hasPrefix(".") }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      return families.filter { query.isEmpty || displayName($0).localizedStandardContains(query) }
    }

    static func presentationHeight(isCompact: Bool, isMixed: Bool, isSearching: Bool) -> CGFloat {
      guard isCompact else { return 320 }
      return isMixed || isSearching ? 244 : 266
    }

    override func loadView() {
      let isCompact = notesChrome?.isActive == true
      let height = Self.presentationHeight(isCompact: isCompact, isMixed: isMixed, isSearching: false)
      preferredContentSize = NSSize(width: 280, height: height)
      view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
      if isCompact {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: "#282A2D")?.cgColor
        view.layer?.borderColor = NSColor(hex: notesChrome?.increasedContrast == true
          ? "#888D92" : "#484A4D")?.cgColor
        view.layer?.borderWidth = 1
        view.layer?.cornerRadius = 10
      }
      searchField.placeholderString = "Search fonts"
      searchField.setAccessibilityLabel("Search fonts")
      searchField.setAccessibilityHelp("Choose a font for \(targetLabel)")
      searchField.delegate = self
      searchField.sendsSearchStringImmediately = true
      searchField.focusRingType = .none
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("family"))
      column.resizingMask = .autoresizingMask
      table.addTableColumn(column)
      table.headerView = nil
      table.focusRingType = .none
      table.rowHeight = 30
      table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
      table.autoresizingMask = [.width]
      table.backgroundColor = .clear
      table.selectionHighlightStyle = .none
      table.dataSource = self
      table.delegate = self
      table.target = self
      table.action = #selector(commitSelection)
      table.onReturn = { [weak self] in self?.commitSelection() }
      table.onCancel = { [weak self] in self?.cancelOperation(nil) }
      table.setAccessibilityLabel("Font families")
      let scroll = isCompact ? CompactFontScrollView() : NSScrollView()
      scroll.focusRingType = .none
      scroll.documentView = table
      scroll.hasVerticalScroller = true
      scroll.verticalScroller = isCompact ? CompactFontFamilyScroller() : FontFamilyScroller()
      scroll.scrollerStyle = .overlay
      scroll.drawsBackground = false
      clearButton.target = self
      clearButton.action = #selector(clearSearch)
      clearButton.bezelStyle = .inline
      clearButton.focusRingType = .none
      let empty = NSStackView(views: [emptyLabel, clearButton])
      empty.orientation = .vertical
      let list = NSView()
      for child in [scroll, empty] {
        child.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(child)
      }
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
        empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: isCompact ? -10 : 0),
      ])
      for child in [searchField, list] {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
      }
      if isCompact {
        let heading = NSTextField(labelWithString: "FONT FAMILY")
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = NSColor(hex: "#AEB3B7")
        let context = NSTextField(labelWithString: isMixed ? "Mixed fonts" : targetLabel)
        context.font = .systemFont(ofSize: 11)
        context.textColor = NSColor(hex: "#AEB3B7")
        for label in [heading, context] {
          label.translatesAutoresizingMaskIntoConstraints = false
          view.addSubview(label)
        }
        NSLayoutConstraint.activate([
          heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
          heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 17),
          context.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
          context.firstBaselineAnchor.constraint(equalTo: heading.firstBaselineAnchor),
          searchField.heightAnchor.constraint(equalToConstant: 29),
          clearButton.widthAnchor.constraint(equalToConstant: 93),
          clearButton.heightAnchor.constraint(equalToConstant: 27),
        ])
        table.style = .plain
        table.intercellSpacing = .zero
        empty.spacing = 10
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = NSColor(hex: "#ECECEA")
        clearButton.isBordered = false
        clearButton.focusRingType = .exterior
        clearButton.attributedTitle = NSAttributedString(
          string: clearButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(hex: "#EBEBE9")!,
          ]
        )
        clearButton.wantsLayer = true
        clearButton.layer?.borderColor = NSColor(hex: notesChrome?.increasedContrast == true
          ? "#888D92" : "#525459")?.cgColor
        clearButton.layer?.borderWidth = 1
        clearButton.layer?.cornerRadius = 5
      }
      NSLayoutConstraint.activate([
        searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: isCompact ? 14 : 12),
        searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: isCompact ? -14 : -12),
        searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: isCompact ? 38 : 12),
        list.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: isCompact ? 5 : 0),
        list.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: isCompact ? -5 : 0),
        list.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: isCompact ? 7 : 8),
        list.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
      ])
      reloadRows()
    }

    override func viewDidLayout() {
      super.viewDidLayout()
      guard let scroll = table.enclosingScrollView else { return }
      let width = scroll.contentView.bounds.width
      if table.frame.width != width {
        table.frame.size.width = width
        table.tableColumns.first?.width = width
      }
      if revealsSelectionAfterLayout, scroll.contentSize.height > 0 {
        revealsSelectionAfterLayout = false
        if !scroll.documentVisibleRect.contains(table.rect(ofRow: table.selectedRow)) {
          table.scrollRowToVisible(table.selectedRow)
        }
      }
    }

    override func viewDidAppear() {
      super.viewDidAppear()
      view.window?.makeFirstResponder(searchField)
      guard notesChrome?.isActive == true else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.view.window != nil, self.table.selectedRow >= 0 else { return }
        self.revealsSelectionAfterLayout = true
        self.view.needsLayout = true
        self.view.layoutSubtreeIfNeeded()
      }
    }

    func controlTextDidChange(_ notification: Notification) {
      updateSearch()
    }

    private func updateSearch() {
      reloadRows()
      let isSearching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      preferredContentSize.height = Self.presentationHeight(
        isCompact: notesChrome?.isActive == true, isMixed: isMixed, isSearching: isSearching
      )
      onSearchChanged(isSearching)
    }

    private func reloadRows() {
      let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      rows = Self.families(from: installedFamilies, query: query)
      if notesChrome?.isActive == true, query.isEmpty {
        let installedSuggestions = Self.notesSuggestions.filter { rows.contains($0) }
        rows = installedSuggestions + rows.filter { !installedSuggestions.contains($0) }
      }
      table.reloadData()
      let appliedFamily = currentFamily.map(Self.normalizedFamily)
      let selected = !isMixed ? rows.firstIndex(of: appliedFamily ?? "") : nil
      table.selectRowIndexes(rows.isEmpty ? [] : IndexSet(integer: selected ?? 0), byExtendingSelection: false)
      emptyLabel.superview?.isHidden = !rows.isEmpty
      if notesChrome?.isActive == true, let scroll = table.enclosingScrollView {
        scroll.isHidden = rows.isEmpty
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        revealsSelectionAfterLayout = table.selectedRow >= 0
        if revealsSelectionAfterLayout { view.needsLayout = true }
      } else if table.selectedRow >= 0 {
        table.scrollRowToVisible(table.selectedRow)
      }
    }

    @objc private func clearSearch() {
      searchField.stringValue = ""
      updateSearch()
      view.window?.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      let family = rows[row]
      let name = NSTextField(labelWithString: Self.displayName(family))
      name.lineBreakMode = .byTruncatingTail
      name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let isCompact = notesChrome?.isActive == true
      let sample: NSTextField =
        if isCompact, notesChrome?.increasedContrast == false {
          FontFamilyPreviewField(labelWithString: "Aa")
        } else {
          NSTextField(labelWithString: "Aa")
        }
      let selected = !isMixed && currentFamily.map(Self.normalizedFamily) == family
      let familyFont = EditorTypography.bodyFont(family: family, size: 17)
      if selected, isCompact, notesChrome?.increasedContrast == false {
        let emphasized = NSFontManager.shared.convert(familyFont, toHaveTrait: .boldFontMask)
        sample.font = emphasized.familyName == familyFont.familyName ? emphasized : familyFont
      } else {
        sample.font = familyFont
      }
      let check = NSTextField(labelWithString: selected ? "✓" : "")
      if let notesChrome, isCompact {
        name.font = .systemFont(ofSize: 12, weight: notesChrome.increasedContrast ? .regular : .light)
        name.textColor = NSColor(hex: "#EBEBEC")
        sample.textColor = NSColor(hex: "#EFEFEF")
        sample.isHidden = isMixed || !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        check.font = .systemFont(ofSize: 12, weight: .regular)
        check.textColor = NSColor(hex: notesChrome.increasedContrast ? "#EFEFF0" : "#C5C7CA")
      }
      let cell = NSView()
      for child in [check, name, sample] {
        child.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(child)
      }
      NSLayoutConstraint.activate([
        check.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: isCompact ? 11 : 10),
        check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        check.widthAnchor.constraint(equalToConstant: 14),
        name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
        name.trailingAnchor.constraint(equalTo: sample.leadingAnchor, constant: -6),
        name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        sample.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: isCompact ? -10 : -24),
        sample.widthAnchor.constraint(equalToConstant: 38),
        sample.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
      ])
      cell.setAccessibilityElement(true)
      cell.setAccessibilityLabel(Self.displayName(family))
      cell.setAccessibilityValue(selected ? "Current font" : "")
      return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let rowView = FontFamilyRowView()
      if notesChrome?.isActive == true { rowView.selectedFill = NSColor(hex: "#3C3E42") }
      return rowView
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch selector {
      case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
        guard !rows.isEmpty else { return true }
        let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
        let row = min(max(table.selectedRow + step, 0), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        commitSelection()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        cancelOperation(nil)
        return true
      default: return false
      }
    }

    @objc func commitSelection() {
      guard rows.indices.contains(table.selectedRow) else { return }
      onCommit(rows[table.selectedRow])
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }
  }

  private final class CompactFontSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
      get { CompactFontSearchCell.self }
      set {}
    }

    private let idleOutline: CGColor
    private let focusOutline: CGColor

    init(increasedContrast: Bool) {
      idleOutline = NSColor(hex: increasedContrast ? "#888D92" : "#66686E")!.cgColor
      focusOutline = NSColor(hex: increasedContrast ? "#D4D7DA" : "#8D919A")!.cgColor
      super.init(frame: .zero)
      font = .systemFont(ofSize: 12)
      if let cancel = (cell as? NSSearchFieldCell)?.cancelButtonCell,
        let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Clear search")?
          .withSymbolConfiguration(.init(pointSize: 8, weight: .regular).applying(.init(
            paletteColors: [NSColor(hex: increasedContrast ? "#EFEFF0" : "#AFB3B7")!]
          )))
      {
        cancel.image = glyph
        cancel.alternateImage = glyph
      }
      drawsBackground = false
      wantsLayer = true
      layer?.backgroundColor = NSColor(hex: "#1D1F21")?.cgColor
      layer?.borderColor = idleOutline
      layer?.borderWidth = 1
      layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
      guard super.becomeFirstResponder() else { return false }
      layer?.borderColor = focusOutline
      return true
    }

    override func textDidEndEditing(_ notification: Notification) {
      super.textDidEndEditing(notification)
      if currentEditor() == nil || window?.firstResponder !== currentEditor() {
        layer?.borderColor = idleOutline
      }
    }
  }

  private final class CompactFontSearchCell: NSSearchFieldCell {
    private weak var activeEditor: NSTextView?
    private var originalCaretColor: NSColor?

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
      let text = super.setUpFieldEditorAttributes(textObj)
      if let editor = text as? NSTextView {
        if activeEditor !== editor {
          activeEditor = editor
          originalCaretColor = editor.insertionPointColor
        }
        editor.insertionPointColor = .white
      }
      return text
    }

    override func endEditing(_ textObj: NSText) {
      if let originalCaretColor {
        activeEditor?.insertionPointColor = originalCaretColor
      }
      activeEditor = nil
      originalCaretColor = nil
      super.endEditing(textObj)
    }
  }

  private final class FontFamilyTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
      if event.keyCode == 36 || event.keyCode == 76 {
        onReturn?()
      } else if event.keyCode == 53 {
        onCancel?()
      } else {
        super.keyDown(with: event)
      }
    }
  }

  private final class FontFamilyRowView: NSTableRowView {
    var selectedFill: NSColor?
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override var isSelected: Bool {
      didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
      let trackingArea = NSTrackingArea(
        rect: .zero,
        options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(trackingArea)
      hoverTrackingArea = trackingArea
      reconcileHover()
    }

    override func mouseEntered(with event: NSEvent) {
      reconcileHover(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
      setHovered(false)
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      if superview == nil { setHovered(false) }
    }

    private func reconcileHover(at locationInWindow: NSPoint? = nil) {
      guard let window, let contentView = window.contentView else {
        setHovered(false)
        return
      }
      let location = locationInWindow ?? window.mouseLocationOutsideOfEventStream
      var hit = contentView.hitTest(contentView.convert(location, from: nil))
      while let candidate = hit {
        if candidate is NSScroller {
          setHovered(false)
          return
        }
        hit = candidate.superview
      }
      var ancestor = superview
      while ancestor != nil, !(ancestor is NSTableView) { ancestor = ancestor?.superview }
      guard let table = ancestor as? NSTableView else {
        setHovered(false)
        return
      }
      let row = table.row(at: table.convert(location, from: nil))
      setHovered(row >= 0 && table.rowView(atRow: row, makeIfNecessary: false) === self)
    }

    private func setHovered(_ hovered: Bool) {
      guard isHovered != hovered else { return }
      isHovered = hovered
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard isSelected || isHovered else { return }
      (isSelected ? selectedFill ?? NSColor.labelColor.withAlphaComponent(0.16)
        : NSColor.labelColor.withAlphaComponent(0.10)).setFill()
      NSBezierPath(
        roundedRect: bounds.insetBy(dx: 4, dy: selectedFill == nil ? 2 : 0),
        xRadius: 5,
        yRadius: 5
      ).fill()
    }
  }

  private final class FontFamilyPreviewField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
      EditorCanvasInk.drawText(grayscale: true) {
        super.draw(dirtyRect)
      }
    }
  }

  private class FontFamilyScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
  }

  private final class CompactFontFamilyScroller: FontFamilyScroller {
    override func rect(for partCode: NSScroller.Part) -> NSRect {
      let rect = super.rect(for: partCode)
      guard partCode == .knob, !rect.isEmpty else { return rect }
      let left = max(bounds.minX + 2, rect.minX - 1)
      let right = min(bounds.maxX - 2, rect.maxX + 1)
      return right > left
        ? NSRect(x: left, y: rect.minY, width: right - left, height: rect.height)
        : rect
    }

    override func drawKnob() {
      let rect = rect(for: .knob).insetBy(dx: 0.5, dy: 0.5)
      guard !rect.isEmpty else { return }
      let radius = min(rect.width, rect.height) / 2
      NSColor.white.withAlphaComponent(0.48).setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
  }

  private final class CompactFontScrollView: NSScrollView {
    override func tile() {
      super.tile()
      guard let scroller = verticalScroller, scroller.frame.width > 0 else { return }
      scroller.frame.origin.x = bounds.maxX - scroller.frame.width - 4
      var viewport = contentView.frame
      viewport.size.width = max(0, min(viewport.width, scroller.frame.minX - 3 - viewport.minX))
      if contentView.frame != viewport { contentView.frame = viewport }
    }
  }

#endif
