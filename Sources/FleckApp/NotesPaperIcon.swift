#if os(macOS)
  import AppKit
  import SwiftUI

  struct NotesPaperIcon: View {
    enum Glyph {
      case highlighter, bullets, numbers, checklist, overflow
      case search, plus, chevron, options, sliders, backlinks, pin, bell, newFolder
      case bold, italic, underline, strikethrough
      case folder, inbox, folderTrash, editorTrash, undo, redo, palette, fontDisclosure
      case microphone, toolsDocument, toolsReplace

      var size: CGFloat {
        switch self {
        case .search, .plus, .chevron, .options, .sliders, .backlinks, .pin, .bell, .newFolder: 18
        case .folder, .inbox, .folderTrash: 18
        case .editorTrash, .undo, .redo, .palette, .microphone: 17
        case .fontDisclosure: 10
        case .toolsDocument, .toolsReplace: 15
        case .highlighter, .bullets, .numbers, .checklist, .overflow, .bold, .italic, .underline, .strikethrough: 17
        }
      }

      var viewBox: CGFloat { self == .bell ? 20 : 24 }
      var strokeWidth: CGFloat { self == .bell ? 1.3 : 2 }
      var ink: String { self == .bell ? "#DCE2E6" : "#C4C7CA" }

      var outline: Path {
        var path = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: CGPoint(x: x, y: y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: CGPoint(x: x, y: y)) }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
          move(x1, y1)
          line(x2, y2)
        }
        func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
          path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        }
        func circle(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) {
          path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        }
        // The editable Paper SVGs use short, circular endpoint arcs. Preserve their
        // centerlines instead of substituting a similarly named symbol font.
        func arc(_ radius: CGFloat, _ x: CGFloat, _ y: CGFloat, clockwise: Bool) {
          guard let start = path.currentPoint else { return }
          let dx = (x - start.x) / 2
          let dy = (y - start.y) / 2
          let distance = dx * dx + dy * dy
          guard distance > 0 else { return }
          let correctedRadius = max(radius, sqrt(distance))
          let factor = sqrt(max(0, correctedRadius * correctedRadius - distance) / distance)
            * (clockwise ? 1 : -1)
          let cx = (start.x + x) / 2 - dy * factor
          let cy = (start.y + y) / 2 + dx * factor
          let angle = atan2(start.y - cy, start.x - cx)
          let span = 2 * asin(min(1, sqrt(distance) / correctedRadius))
          path.addRelativeArc(
            center: CGPoint(x: cx, y: cy), radius: correctedRadius,
            startAngle: .radians(Double(angle)), delta: .radians(Double(clockwise ? span : -span))
          )
        }
        switch self {
        case .folder, .newFolder:
          if self == .newFolder {
            line(12, 10, 12, 16)
            line(9, 13, 15, 13)
          }
          move(20, 20)
          arc(2, 22, 18, clockwise: false)
          line(22, 8)
          arc(2, 20, 6, clockwise: false)
          line(12.1, 6)
          arc(2, 10.41, 5.1, clockwise: true)
          line(9.6, 3.9)
          arc(2, 7.93, 3, clockwise: false)
          line(4, 3)
          arc(2, 2, 5, clockwise: false)
          line(2, 18)
          arc(2, 4, 20, clockwise: false)
          path.closeSubpath()
        case .inbox:
          move(22, 12)
          line(16, 12)
          line(14, 15)
          line(10, 15)
          line(8, 12)
          line(2, 12)
          move(5.45, 5.11)
          line(2, 12)
          line(2, 18)
          arc(2, 4, 20, clockwise: false)
          line(20, 20)
          arc(2, 22, 18, clockwise: false)
          line(22, 12)
          line(18.55, 5.11)
          arc(2, 16.76, 4, clockwise: false)
          line(7.24, 4)
          arc(2, 5.45, 5.11, clockwise: false)
          path.closeSubpath()
        case .folderTrash, .editorTrash:
          line(3, 6, 21, 6)
          move(19, 6)
          line(19, 20)
          curve(19, 21, 18, 22, 17, 22)
          line(7, 22)
          curve(6, 22, 5, 21, 5, 20)
          line(5, 6)
          move(8, 6)
          line(8, 4)
          curve(8, 3, 9, 2, 10, 2)
          line(14, 2)
          curve(15, 2, 16, 3, 16, 4)
          line(16, 6)
          line(10, 11, 10, 17)
          line(14, 11, 14, 17)
        case .undo, .redo:
          move(9, 14)
          line(4, 9)
          line(9, 4)
          move(4, 9)
          line(14.5, 9)
          arc(5.5, 20, 14.5, clockwise: true)
          arc(5.5, 14.5, 20, clockwise: true)
          line(11, 20)
          if self == .redo {
            path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0))
          }
        case .palette:
          circle(13.5, 6.5, radius: 0.5)
          circle(17.5, 10.5, radius: 0.5)
          circle(8.5, 7.5, radius: 0.5)
          circle(6.5, 12.5, radius: 0.5)
          move(12, 2)
          curve(6.5, 2, 2, 6.5, 2, 12)
          curve(2, 17.5, 6.5, 22, 12, 22)
          curve(12.926, 22, 13.648, 21.254, 13.648, 20.312)
          curve(13.648, 19.875, 13.468, 19.477, 13.211, 19.187)
          curve(12.921, 18.898, 12.773, 18.535, 12.773, 18.062)
          arc(1.64, 14.441, 16.394, clockwise: true)
          line(16.437, 16.394)
          curve(19.488, 16.394, 21.992, 13.891, 21.992, 10.84)
          curve(21.965, 6.012, 17.461, 2, 12, 2)
          path.closeSubpath()
        case .fontDisclosure:
          move(6, 9)
          line(12, 15)
          line(18, 9)
        case .toolsDocument:
          move(15, 2)
          line(6, 2)
          arc(2, 4, 4, clockwise: false)
          line(4, 20)
          arc(2, 6, 22, clockwise: false)
          line(18, 22)
          arc(2, 20, 20, clockwise: false)
          line(20, 7)
          path.closeSubpath()
          move(14, 2)
          line(14, 6)
          arc(2, 16, 8, clockwise: false)
          line(20, 8)
          line(10, 9, 8, 9)
          line(16, 13, 8, 13)
          line(16, 17, 8, 17)
        case .toolsReplace:
          move(21, 16)
          line(17, 20)
          line(13, 16)
          line(17, 20, 17, 4)
          move(3, 8)
          line(7, 4)
          line(11, 8)
          line(7, 4, 7, 20)
        case .microphone:
          move(12, 2)
          arc(3, 9, 5, clockwise: false)
          line(9, 12)
          arc(3, 15, 12, clockwise: false)
          line(15, 5)
          arc(3, 12, 2, clockwise: false)
          path.closeSubpath()
          move(19, 10)
          line(19, 12)
          arc(7, 5, 12, clockwise: true)
          line(5, 10)
          line(12, 19, 12, 22)
        case .bold: // Paper 7A2-0.
          move(6, 12)
          line(15, 12)
          arc(4, 15, 20, clockwise: true)
          line(7, 20)
          arc(1, 6, 19, clockwise: true)
          line(6, 5)
          arc(1, 7, 4, clockwise: true)
          line(14, 4)
          arc(4, 14, 12, clockwise: true)
        case .italic: // Paper 7A6-0.
          line(19, 4, 10, 4)
          line(14, 20, 5, 20)
          line(15, 4, 9, 20)
        case .underline: // Paper 7AC-0.
          move(6, 4)
          line(6, 10)
          arc(6, 18, 10, clockwise: false)
          line(18, 4)
          line(4, 20, 20, 20)
        case .strikethrough: // Paper 7AH-0.
          move(16, 4)
          line(9, 4)
          arc(3, 6.17, 8, clockwise: false)
          move(14, 12)
          arc(4, 14, 20, clockwise: true)
          line(6, 20)
          line(4, 12, 20, 12)
        case .bell: // Paper 76Y-0.
          move(5, 8)
          arc(5, 15, 8, clockwise: true)
          line(15, 12)
          line(17, 14)
          line(3, 14)
          line(5, 12)
          path.closeSubpath()
          line(8, 17, 12, 17)
        case .backlinks: // Paper 772-0.
          move(10, 13)
          arc(5, 17.54, 13.54, clockwise: false)
          line(20.54, 10.54)
          arc(5, 13.47, 3.47, clockwise: false)
          line(11.75, 5.18)
          move(14, 11)
          arc(5, 6.46, 10.46, clockwise: false)
          line(3.46, 13.46)
          arc(5, 10.53, 20.53, clockwise: false)
          line(12.24, 18.82)
        case .pin: // Paper 77H-0, the unpinned trigger only.
          line(12, 17, 12, 22)
          move(9, 10.76)
          arc(2, 7.89, 12.55, clockwise: true)
          line(6.11, 13.45)
          arc(2, 5, 15.24, clockwise: false)
          line(5, 16)
          arc(1, 6, 17, clockwise: false)
          line(18, 17)
          arc(1, 19, 16, clockwise: false)
          line(19, 15.24)
          arc(2, 17.89, 13.45, clockwise: false)
          line(16.11, 12.55)
          arc(2, 15, 10.76, clockwise: true)
          line(15, 7)
          arc(1, 16, 6, clockwise: true)
          arc(2, 16, 2, clockwise: false)
          line(8, 2)
          arc(2, 8, 6, clockwise: false)
          arc(1, 9, 7, clockwise: true)
          path.closeSubpath()
        case .highlighter:
          move(9, 11)
          line(3, 17)
          line(3, 20)
          line(12, 20)
          line(15, 17)
          move(22, 12)
          line(17.4, 16.6)
          curve(16.622, 17.362, 15.378, 17.362, 14.6, 16.6)
          line(9.4, 11.4)
          curve(8.638, 10.622, 8.638, 9.378, 9.4, 8.6)
          line(14, 4)
        case .bullets:
          for y: CGFloat in [6, 12, 18] {
            line(3, y, 3.01, y)
            line(8, y, 21, y)
          }
        case .numbers:
          for y: CGFloat in [6, 12, 18] { line(10, y, 21, y) }
          line(4, 10, 6, 10)
          move(4, 6)
          line(5, 6)
          line(5, 10)
          move(6, 18)
          line(4, 18)
          curve(4, 17, 6, 16, 6, 15)
          curve(6, 14, 5, 13.5, 4, 14)
        case .checklist:
          for y: CGFloat in [7, 17] {
            move(3, y)
            line(5, y + 2)
            line(9, y - 2)
          }
          for y: CGFloat in [6, 12, 18] { line(13, y, 21, y) }
        case .overflow:
          for x: CGFloat in [5, 12, 19] { circle(x, 12, radius: 1) }
        case .search:
          circle(11, 11, radius: 8)
          line(21, 21, 16.7, 16.7)
        case .plus:
          line(5, 12, 19, 12)
          line(12, 5, 12, 19)
        case .chevron:
          move(18, 15)
          line(12, 9)
          line(6, 15)
        case .options:
          circle(12, 12, radius: 10)
          for x: CGFloat in [7, 12, 17] { line(x, 12, x + 0.01, 12) }
        case .sliders:
          line(21, 4, 14, 4)
          line(10, 4, 3, 4)
          line(21, 12, 12, 12)
          line(8, 12, 3, 12)
          line(21, 20, 16, 20)
          line(12, 20, 3, 20)
          line(14, 2, 14, 6)
          line(8, 10, 8, 14)
          line(16, 18, 16, 22)
        }
        return path
      }
    }

    @Environment(\.fleckThemeSnapshot) private var theme
    let glyph: Glyph
    var highlightInk: Color? = nil
    var drawSize: CGFloat? = nil

    var body: some View {
      let size = drawSize ?? glyph.size
      let scale = size / glyph.viewBox
      let transform = CGAffineTransform(scaleX: scale, y: scale)
      let outline = glyph.outline.applying(transform)
      let highContrastInk = Color(nsColor: NSColor(hex: "#F2F2F0")!)
      let stroke = StrokeStyle(
        lineWidth: glyph.strokeWidth * scale,
        lineCap: glyph == .bell ? .butt : .round,
        lineJoin: glyph == .bell ? .miter : .round
      )
      ZStack {
        if let highlightInk {
          Path { path in
            path.move(to: CGPoint(x: 4, y: 18))
            path.addLine(to: CGPoint(x: 5.5, y: 16.5))
            path.addLine(to: CGPoint(x: 9, y: 20))
            path.addLine(to: CGPoint(x: 4, y: 20))
            path.closeSubpath()
          }
          .applying(transform)
          .fill(highlightInk)
        }
        outline
          .stroke(
            theme.increasedContrast ? highContrastInk : Color(nsColor: NSColor(hex: glyph.ink)!),
            style: stroke
          )
          .overlay {
            if glyph == .options && !theme.increasedContrast {
              outline.stroke(highContrastInk, style: stroke)
                .mask { Rectangle().frame(width: 14 * scale, height: 4 * scale) }
            }
          }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
    }
  }
#endif
