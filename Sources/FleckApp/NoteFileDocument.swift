#if os(macOS)
  import FleckCore
  import SwiftUI
  import UniformTypeIdentifiers

  struct PreparedNoteFileExport {
    let document: NoteFileDocument
    let filename: String
    let type: UTType

    init(note: Note, format: NoteExportFormat) {
      let export = NoteExport(note: note, format: format)
      document = NoteFileDocument(data: export.data)
      filename = export.suggestedFilename
      switch format {
      case .plainText: type = .plainText
      case .markdown: type = NoteFileDocument.markdownContentType
      case .richText: type = .rtf
      }
    }
  }

  struct NoteFileDocument: FileDocument {
    static let markdownContentType = UTType(filenameExtension: "md") ?? .plainText
    static let readableContentTypes: [UTType] = [.plainText, markdownContentType, .rtf]

    var data: Data

    init(data: Data = Data()) {
      self.data = data
    }

    init(configuration: ReadConfiguration) throws {
      data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
      exportFileWrapper()
    }

    func exportFileWrapper() -> FileWrapper {
      FileWrapper(regularFileWithContents: data)
    }
  }
#endif
