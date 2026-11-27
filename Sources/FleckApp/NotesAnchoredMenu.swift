#if os(macOS)
  import SwiftUI

  struct NotesMenuAction {
    let title: String
    var symbol: String? = nil
    var paperGlyph: NotesPaperIcon.Glyph? = nil
    var isEnabled = true
    let perform: () -> Void
  }

  enum NotesMenuPlacement: Equatable {
    case belowTrailing
    case alongside

    func frame(
      anchor: CGRect, menuSize: CGSize, screen: CGRect,
      firstRowInset: CGFloat = 0, prefersLeft: Bool = false
    ) -> CGRect {
      let gap: CGFloat = 4
      let x: CGFloat
      let y: CGFloat
      switch self {
      case .belowTrailing:
        let below = anchor.minY - gap - menuSize.height
        let above = anchor.maxY + gap
        let belowRoom = anchor.minY - screen.minY
        let aboveRoom = screen.maxY - anchor.maxY
        x = anchor.maxX - menuSize.width
        y = below >= screen.minY || belowRoom >= aboveRoom ? below : above
      case .alongside:
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - menuSize.width
        let rightRoom = screen.maxX - anchor.maxX
        let leftRoom = anchor.minX - screen.minX
        if prefersLeft, left >= screen.minX {
          x = left
        } else if right + menuSize.width <= screen.maxX {
          x = right
        } else if left >= screen.minX {
          x = left
        } else {
          x = rightRoom >= leftRoom ? right : left
        }
        y = anchor.maxY + firstRowInset - menuSize.height
      }
      return CGRect(
        x: min(max(x, screen.minX), max(screen.minX, screen.maxX - menuSize.width)),
        y: min(max(y, screen.minY), max(screen.minY, screen.maxY - menuSize.height)),
        width: menuSize.width, height: menuSize.height
      )
    }
  }
#endif
