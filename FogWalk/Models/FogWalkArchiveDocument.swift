import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let fogWalkArchive = UTType(
        exportedAs: "com.citywalk.fogwalk.archive",
        conformingTo: .data
    )

    static let gpx = UTType(
        importedAs: "com.topografix.gpx",
        conformingTo: .xml
    )
}

struct FogWalkArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fogWalkArchive] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
