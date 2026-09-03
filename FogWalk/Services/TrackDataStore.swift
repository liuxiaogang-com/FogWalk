import Foundation

enum TrackDataStoreError: LocalizedError {
    case unsupportedArchiveVersion(Int)
    case emptyArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedArchiveVersion(let version):
            return "这个足迹备份版本（\(version)）暂时不受支持。"
        case .emptyArchive:
            return "备份中没有可用的足迹数据。"
        }
    }
}

struct TrackArchive: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let dataset: TrackDataset
}

enum TrackArchiveCodec {
    static func encode(_ dataset: TrackDataset) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(
            TrackArchive(
                version: TrackArchive.currentVersion,
                exportedAt: Date(),
                dataset: dataset
            )
        )
    }

    static func decode(_ data: Data) throws -> TrackDataset {
        let archive = try PropertyListDecoder().decode(TrackArchive.self, from: data)
        guard archive.version == TrackArchive.currentVersion else {
            throw TrackDataStoreError.unsupportedArchiveVersion(archive.version)
        }
        guard !archive.dataset.points.isEmpty else {
            throw TrackDataStoreError.emptyArchive
        }
        return archive.dataset
    }
}

actor TrackDataStore {
    private let archiveURL: URL

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogWalk", isDirectory: true)
        archiveURL = root.appendingPathComponent("library.fogwalk")
    }

    func load() throws -> TrackDataset? {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return nil }
        return try TrackArchiveCodec.decode(Data(contentsOf: archiveURL, options: .mappedIfSafe))
    }

    func save(_ dataset: TrackDataset) throws {
        let directory = archiveURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try TrackArchiveCodec.encode(dataset)
        try data.write(to: archiveURL, options: .atomic)
    }
}
