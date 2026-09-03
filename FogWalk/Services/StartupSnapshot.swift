import Foundation

struct RestoredStartup: Sendable {
    let summary: ImportSummary
    let grid: ExplorationGrid
    let presentations: [TrackTimeFilter: TrackPresentation]
}

/// Disposable derived data. Bump the schema when coordinate, connection, or fog rules change.
struct StartupSnapshot: Codable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let summary: ImportSummary
    let grid: ExplorationGrid
    let presentations: [CachedPresentation]

    static func build(dataset: TrackDataset) -> StartupSnapshot {
        let calendar = Calendar.current
        return StartupSnapshot(
            version: schemaVersion,
            calendarIdentifier: String(describing: calendar.identifier),
            timeZoneIdentifier: calendar.timeZone.identifier,
            summary: dataset.summary,
            grid: ExplorationGrid(points: dataset.points),
            presentations: TrackTimeFilter.allCases.enumerated().map { index, filter in
                CachedPresentation(TrackProcessor.makePresentation(
                    dataset: dataset, filter: filter, revision: index + 1, calendar: calendar
                ))
            }
        )
    }

    var isCompatible: Bool {
        version == Self.schemaVersion
            && calendarIdentifier == String(describing: Calendar.current.identifier)
            && timeZoneIdentifier == Calendar.current.timeZone.identifier
            && summary.uniqueCount > 0
            && Set(presentations.map(\.filter)) == Set(TrackTimeFilter.allCases)
            && presentations.count == TrackTimeFilter.allCases.count
    }

    func restoredPresentations() throws -> [TrackTimeFilter: TrackPresentation] {
        var result: [TrackTimeFilter: TrackPresentation] = [:]
        for cached in presentations { result[cached.filter] = try cached.restore() }
        return result
    }
}

struct CachedPresentation: Codable, Sendable {
    let revision: Int
    let filter: TrackTimeFilter
    let segments: [Data]
    let isolated: Data
    let visiblePointCount: Int
    let totalDistanceMeters: Double
    let referenceDate: Date?
    let latestCoordinate: GeoCoordinate?

    init(_ value: TrackPresentation) {
        revision = value.revision
        filter = value.filter
        segments = value.segments.map { PackedCoordinates.encode($0.coordinates) }
        isolated = PackedCoordinates.encode(value.isolatedPoints)
        visiblePointCount = value.visiblePointCount
        totalDistanceMeters = value.totalDistanceMeters
        referenceDate = value.referenceDate
        latestCoordinate = value.latestCoordinate
    }

    func restore() throws -> TrackPresentation {
        TrackPresentation(
            revision: revision, filter: filter,
            segments: try segments.enumerated().map { index, bytes in
                TrackSegment(id: index, coordinates: try PackedCoordinates.decode(bytes))
            },
            isolatedPoints: try PackedCoordinates.decode(isolated),
            visiblePointCount: visiblePointCount, totalDistanceMeters: totalDistanceMeters,
            referenceDate: referenceDate, latestCoordinate: latestCoordinate
        )
    }
}

enum SnapshotError: Error { case invalidBytes }

/// Explicit little endian IEEE-754 doubles: lossless and independent of plist object overhead.
enum PackedCoordinates {
    static func encode(_ coordinates: [GeoCoordinate]) -> Data {
        var data = Data(capacity: coordinates.count * 16)
        for coordinate in coordinates {
            var latitude = coordinate.latitude.bitPattern.littleEndian
            var longitude = coordinate.longitude.bitPattern.littleEndian
            withUnsafeBytes(of: &latitude) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &longitude) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) throws -> [GeoCoordinate] {
        guard data.count % 16 == 0 else { throw SnapshotError.invalidBytes }
        return try data.withUnsafeBytes { bytes in
            var result = [GeoCoordinate]()
            result.reserveCapacity(data.count / 16)
            for offset in stride(from: 0, to: data.count, by: 16) {
                let latitude = Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                let longitude = Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
                guard latitude.isFinite, longitude.isFinite,
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                    throw SnapshotError.invalidBytes
                }
                result.append(GeoCoordinate(latitude: latitude, longitude: longitude))
            }
            return result
        }
    }
}
