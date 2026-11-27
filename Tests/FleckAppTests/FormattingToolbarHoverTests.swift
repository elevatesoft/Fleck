import Foundation
import Testing

@Suite("FormattingToolbarHover")
struct FormattingToolbarHoverTests {
  @Test func sharedStyleOwnsPerButtonHoverWithoutChangingGeometry() throws {
    let source = try notesPanelSource()
    let styleStart = try #require(source.range(of: "private struct CrispToolbarButtonStyle"))
    let styleEnd = try #require(source.range(
      of: "struct FluidTabReorder:", range: styleStart.upperBound..<source.endIndex
    ))
    let style = source[styleStart.lowerBound..<styleEnd.lowerBound]

    #expect(style.contains("CrispToolbarButtonBody(configuration: configuration, motion: motion)"))
    #expect(style.contains("@Environment(\\.isEnabled) private var isEnabled"))
    #expect(style.contains("@State private var isHovered = false"))
    #expect(style.contains(".onHover { isHovered = $0 }"))
    #expect(style.contains("isEnabled && isHovered"))
    #expect(style.contains("Color.primary.opacity(0.10)"))
    #expect(style.contains("RoundedRectangle(cornerRadius: 5)"))
    #expect(style.contains(".scaleEffect(configuration.isPressed ? motion.pressScale : 1)"))
    #expect(style.contains(".animation(motion.quick, value: configuration.isPressed)"))
    #expect(!style.contains(".padding("))
    #expect(!style.contains(".frame("))
    #expect(!style.contains(".overlay("))
  }

  @Test func existingIconTargetsAndSelectedStateRemainIntact() throws {
    let source = try notesPanelSource()
    let marker = try #require(
      source.components(separatedBy: "struct HighlighterMarkerIcon: View").last?
        .components(separatedBy: "private struct ToolbarIconLabel").first
    )
    let icon = try #require(
      source.components(separatedBy: "private struct ToolbarIconLabel").last?
        .components(separatedBy: "private struct FormattingMenuIconLabel").first
    )
    let overflow = try #require(
      source.components(separatedBy: "struct FormattingOverflowLabel").last?
        .components(separatedBy: "#endif").first
    )

    #expect(marker.contains(".frame(width: 28, height: 26)"))
    #expect(marker.contains(".contentShape(RoundedRectangle(cornerRadius: 5))"))
    let target = ".frame(width: 28, height: NotesSolidChrome(theme: theme, appearance: appearance).isActive ? 28 : 26)"
    #expect(icon.contains(target))
    #expect(overflow.contains(target))
    #expect(icon.contains("isActive ? theme.color(.selectionFill) : .clear"))
    #expect(icon.contains(".contentShape(RoundedRectangle(cornerRadius: 5))"))
    #expect(overflow.contains(".contentShape(RoundedRectangle(cornerRadius: 5))"))
  }

  @Test func fontSizeFieldUsesNeutralKeyboardFocusStyling() throws {
    let source = try notesPanelSource()
    let field = try #require(
      source.components(separatedBy: "private func fontSizeField(").last?
        .components(separatedBy: "private var isFontTitleTarget").first
    )
    let cancel = try #require(
      source.components(separatedBy: "private func discardSolidFontSize(").last?
        .components(separatedBy: "private func submitSolidFontSize(").first
    )

    #expect(field.contains(".textFieldStyle(.plain)"))
    #expect(field.contains(".focusEffectDisabled()"))
    #expect(field.contains(".multilineTextAlignment(.center)"))
    #expect(field.contains(".monospacedDigit()"))
    #expect(source.contains("fontSizeFieldWidth: CGFloat { solidChrome.isActive ? 38 : 48 }"))
    #expect(field.contains(".frame(width: fontSizeFieldWidth, height: solidChrome.isActive ? 28 : nil)"))
    #expect(field.contains(".focused($focusedFontSizeField, equals: field)"))
    #expect(field.contains(".overlay(alignment: .bottom)"))
    #expect(field.contains("let isFontSizeFocused = focusedFontSizeField == field"))
    #expect(field.contains(".strokeBorder("))
    #expect(field.contains("theme.color(.focusRing)"))
    #expect(field.contains("theme.color(.accent)"))
    #expect(field.contains("isFontSizeHovered ? Color.primary.opacity(0.22) : .clear"))
    #expect(field.contains(".onHover { isFontSizeHovered = $0 }"))
    #expect(!field.contains(".fleckNeutralControlOutline("))
    #expect(!field.contains(".border("))
    #expect(field.contains(".accessibilityLabel(\"Font size\")"))
    #expect(!field.contains(".textFieldStyle(.roundedBorder)"))
    #expect(field.contains(".onSubmit {"))
    #expect(field.contains("submitSolidFontSize(field, dismissPicker: field != .direct, overflowDraft: overflowDraft?.wrappedValue)"))
    #expect(field.contains("else if oldField == field && newField != field {"))
    #expect(field.contains("applyFontSizeText(targetNoteID: targetNoteID)"))
    #expect(field.contains("solidFontSizeEdit?.id == edit.id"))
    #expect(field.contains(".onExitCommand(perform: handlesEscape ?"))
    #expect(field.contains(".onKeyPress(.escape)"))
    #expect(field.contains("if overflowDraft != nil || focusedFontSizeField == field { discardSolidFontSize(field) }"))
    let clearDraft = try #require(cancel.range(of: "solidFontSizeEdit = nil"))
    let clearFocus = try #require(cancel.range(of: "focusedFontSizeField = nil"))
    #expect(clearDraft.upperBound <= clearFocus.lowerBound)
    #expect(cancel.contains("if dismissPicker, field != .direct, presentedPopover == .fontSize"))
    let value = try #require(field.range(of: ".accessibilityValue("))
    let hint = try #require(field.range(of: ".accessibilityHint("))
    try #require(value.upperBound <= hint.lowerBound)
    let accessibilityValue = field[value.upperBound..<hint.lowerBound]
    #expect(accessibilityValue.contains("overflowDraft?.wrappedValue"))
    #expect(accessibilityValue.contains("solidChrome.isActive && solidFontSizeEdit?.field == field"))
    #expect(accessibilityValue.contains("solidFontSizeEdit?.text : nil"))
    #expect(accessibilityValue.contains("?? (commands.isFontSizeMixed ? \"Mixed\" : fontSizeDisplay)"))
    #expect(field.contains(".accessibilityHint(\"Enter a size from 1 through 512 points.\")"))
  }

  @Test func narrowSizeUsesItsOwnDraftAndTheFullActionRow() throws {
    let source = try notesPanelSource()
    let menu = try notesSource(named: "NotesToolsMenu")
    let row = try #require(source.components(separatedBy: "return NotesCascadeItem(\"Font Size…\"").last?
      .components(separatedBy: "case .fontColor:").first)
    let surface = try #require(menu.components(separatedBy: "private struct NotesCascadeSurface: View").last)
    let size = try #require(source.components(separatedBy: "private var fontSizePickerContent:").last?
      .components(separatedBy: "private var foregroundColorPickerContent:").first)
    #expect(source.contains("NotesFormattingCascade(items: overflowItems(items), chrome: solidChrome)"))
    #expect(row.contains("accessibilityLabel: \"Font Size\""))
    #expect(row.contains("perform: presentFontSizePicker"))
    #expect(menu.contains("item == nil ? 11 : 29"))
    #expect(surface.contains("Button(role: item.role) { activate(index) } label:"))
    #expect(surface.contains("Text(item.title)"))
    #expect(surface.contains("Spacer(minLength: 0)"))
    #expect(surface.contains(".frame(height: style.height(of: item))\n              .contentShape(Rectangle())"))
    #expect(size.contains("SolidOverflowSizeDraft { draft in"))
    #expect(size.contains("fontSizeField(field: edit.field, overflowDraft: draft)"))
    #expect(size.contains("submitSolidFontSize(edit.field, dismissPicker: true, overflowDraft: draft.wrappedValue)"))
    #expect(size.contains(".id(edit.field)"))
  }

  private func notesPanelSource() throws -> String {
    try notesSource(named: "NotesPanel")
  }

  private func notesSource(named name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent("Sources/FleckApp/\(name).swift"),
      encoding: .utf8
    )
  }
}
