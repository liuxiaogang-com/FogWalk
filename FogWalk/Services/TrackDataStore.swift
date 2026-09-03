import Foundation
import CryptoKit

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
    static let currentVersion = 2

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
        guard (1...TrackArchive.currentVersion).contains(archive.version) else {
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
    private let snapshotURL: URL

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogWalk", isDirectory: true)
        archiveURL = root.appendingPathComponent("library.fogwalk")
        snapshotURL = root.appendingPathComponent("startup-v1.cache")
    }

    /// File identity changes on our atomic archive replacement, including same-size imports.
    private struct ArchiveIdentity: Codable, Equatable {
        let size: UInt64
        let inode: UInt64
        let modified: Date
    }

    private struct SnapshotEnvelope: Codable {
        let identity: ArchiveIdentity
        let payload: Data
        let checksum: Data
    }

    private func identity() throws -> ArchiveIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        guard let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw SnapshotError.invalidBytes
        }
        return ArchiveIdentity(size: size.uint64Value, inode: inode.uint64Value, modified: modified)
    }

    func loadStartup() -> RestoredStartup? {
        // Any missing/stale/corrupt cache is a cache miss, never a lost-library error.
        do {
            let source = try identity()
            let bytes = try Data(contentsOf: snapshotURL, options: .mappedIfSafe)
            let envelope = try PropertyListDecoder().decode(SnapshotEnvelope.self, from: bytes)
            guard envelope.identity == source,
                  Data(SHA256.hash(data: envelope.payload)) == envelope.checksum else { return nil }
            let snapshot = try PropertyListDecoder().decode(StartupSnapshot.self, from: envelope.payload)
            guard snapshot.isCompatible, try identity() == source else { return nil }
            return RestoredStartup(summary: snapshot.summary, grid: snapshot.grid,
                                   presentations: try snapshot.restoredPresentations())
        } catch { return nil }
    }

    func saveStartup(_ snapshot: StartupSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(snapshot)
        let envelope = SnapshotEnvelope(identity: try identity(), payload: payload,
                                        checksum: Data(SHA256.hash(data: payload)))
        try encoder.encode(envelope).write(to: snapshotURL, options: .atomic)
        var cacheURL = snapshotURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cacheURL.setResourceValues(values)
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
