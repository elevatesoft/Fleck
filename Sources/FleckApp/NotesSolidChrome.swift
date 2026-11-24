#if os(macOS)
  import AppKit
  import SwiftUI
  import FleckCore

  struct NotesSolidChrome {
    let isActive: Bool
    let increasedContrast: Bool

    init(theme: FleckThemeSnapshot, appearance: FleckChromeAppearance) {
      isActive = theme.colorTheme == .monochrome && theme.appearance == .dark
        && appearance == .solid
      increasedContrast = theme.increasedContrast
    }

    var outline: Color {
      color(increasedContrast ? "#888D92" : "#404244")
    }

    var separator: Color {
      color(increasedContrast ? "#888D92" : "#3B3D40")
    }

    var toolbarSurface: Color { color("#222426") }
    var toolbarOutline: Color { increasedContrast ? outline : color("#303234") }
    var toolbarField: Color { color("#2C2E31") }
    var popoverSurface: Color { color("#282A2D") }
    var popoverOutline: Color { increasedContrast ? outline : color("#484A4D") }
    var popoverSeparator: Color { increasedContrast ? outline : color("#424448") }
    var popoverSelection: Color { color("#3C3E42") }
    var dialogSurface: Color { color("#202224") }
    var dialogHeader: Color { color("#242628") }
    var dialogSeparator: Color { increasedContrast ? outline : color("#333537") }
    var webLinkSurface: Color { color("#202123") }
    var webLinkField: Color { color("#171819") }
    var webLinkFieldOutline: Color { increasedContrast ? outline : color("#3A3B3C") }
    var webLinkFocusOutline: Color { color(increasedContrast ? "#D4D7DA" : "#8D919A") }
    var webLinkButton: Color { color("#37393D") }
    var historySurface: Color { color("#191B1E") }
    var historyHeader: Color { color("#202226") }
    var historyOutline: Color { increasedContrast ? outline : color("#42454A") }
    var historySeparator: Color { increasedContrast ? outline : color("#3B3E43") }
    var historyDone: Color { color("#E1E3E7") }

    private func color(_ hex: String) -> Color {
      Color(nsColor: NSColor(hex: hex)!)
    }
  }

  struct NotesSolidActionStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat
    let ink: Color
    var surface: Color = .clear
    var outline: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
      let shape = RoundedRectangle(cornerRadius: 6)
      configuration.label
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .frame(minWidth: width, minHeight: height)
        .fleckHoverFill(in: shape)
        .background(surface, in: shape)
        .overlay { shape.strokeBorder(outline, lineWidth: 1).allowsHitTesting(false) }
        .opacity(configuration.isPressed ? 0.78 : 1)
        .contentShape(Rectangle())
    }
  }

#endif
