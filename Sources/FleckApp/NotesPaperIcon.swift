#if os(macOS)
  import AppKit
  import SwiftUI

  struct NotesPaperIcon: View {
    enum Glyph {
      case highlighter, bullets, numbers, checklist, overflow
      case search, plus, chevron, options, sliders

      var size: CGFloat {
        switch self {
        case .search, .plus, .chevron, .options, .sliders: 18
        case .highlighter, .bullets, .numbers, .checklist, .overflow: 17
        }
      }

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
        switch self {
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

    var body: some View {
      let scale = glyph.size / 24
      let transform = CGAffineTransform(scaleX: scale, y: scale)
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
        glyph.outline.applying(transform)
          .stroke(
            Color(nsColor: NSColor(hex: theme.increasedContrast ? "#F2F2F0" : "#C4C7CA")!),
            style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
          )
      }
      .frame(width: glyph.size, height: glyph.size)
      .accessibilityHidden(true)
    }
  }
#endif
