#if os(macOS) && DEBUG
  import AppKit

  // Temporary isolated diagnostic. Remove rather than shipping this trace.
  @MainActor
  enum FolderRenameFocusTrace {
    private static var events: [String]?
    private static var truncated = false

    static func begin() {
      events = []
      truncated = false
    }

    static func end() {
      events = nil
    }

    static func record(_ event: @autoclosure () -> String) {
      guard let count = events?.count else { return }
      guard count < 128 else { truncated = true; return }
      events?.append(event())
    }

    static func fieldState(_ field: NSTextField) -> String {
      let window = field.window
      let responder = window?.firstResponder
      let editor = field.currentEditor()
      let kind = responder.map { String(describing: type(of: $0)) } ?? "none"
      return "editor=\(editor != nil) owns=\(editor != nil && responder === editor)"
        + " accepts=\(field.acceptsFirstResponder) key=\(window?.isKeyWindow == true)"
        + " responderKind=\(kind)"
    }

    static func report() {
      guard let events else { return }
      print("FLECK_FOLDER_FOCUS_TRACE count=\(events.count) truncated=\(truncated)")
      for (index, event) in events.enumerated() {
        print("FLECK_FOLDER_FOCUS_TRACE \(index) \(event)")
      }
    }
  }
#endif
