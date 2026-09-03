import Foundation
import CoreLocation

enum TrackSource: String, Sendable, Codable {
    case recordedCSV
    case photoCSV
    case gpx
}

struct GeoCoordinate: Hashable, Sendable, Codable {
    let latitude: Double
    let longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct TrackPoint: Identifiable, Hashable, Sendable, Codable {
    let id: Int64
    let timestamp: Date
    let coordinate: GeoCoordinate
    let horizontalAccuracy: Double
    let speed: Double
    let altitude: Double
    let source: TrackSource

    var timestampSeconds: Int64 {
        Int64(timestamp.timeIntervalSince1970.rounded())
    }
}

struct TrackPointKey: Hashable, Sendable {
    let timestamp: Int64
    let latitudeE4: Int32
    let longitudeE4: Int32

    init(timestamp: Int64, latitude: Double, longitude: Double) {
        self.timestamp = timestamp
        // CSV stores six decimals while GPX stores eight. A time-identical point
        // within roughly 10 m is the same sample, even at a rounding boundary.
        latitudeE4 = Int32((latitude * 10_000).rounded())
        longitudeE4 = Int32((longitude * 10_000).rounded())
    }

    init(_ point: TrackPoint) {
        self.init(
            timestamp: point.timestampSeconds,
            latitude: point.coordinate.latitude,
            longitude: point.coordinate.longitude
        )
    }
}

struct ImportSummary: Sendable, Equatable, Codable {
    let recordedCSVCount: Int
    let photoCSVCount: Int
    let gpxCount: Int
    let duplicateCount: Int
    let uniqueCount: Int
    let earliestDate: Date?
    let latestDate: Date?
}

struct TrackDataset: Sendable, Codable {
    let points: [TrackPoint]
    let summary: ImportSummary
}

enum TrackTimeFilter: String, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case sevenDays = "七日"
    case month = "本月"
    case lifetime = "一生"

    var id: Self { self }
}

struct TrackSegment: Identifiable, Sendable {
    let id: Int
    let coordinates: [GeoCoordinate]
}

struct TrackPresentation: Sendable {
    static let empty = TrackPresentation(
        revision: 0,
        filter: .today,
        segments: [],
        isolatedPoints: [],
        visiblePointCount: 0,
        totalDistanceMeters: 0,
        referenceDate: nil,
        latestCoordinate: nil
    )

    let revision: Int
    let filter: TrackTimeFilter
    let segments: [TrackSegment]
    let isolatedPoints: [GeoCoordinate]
    let visiblePointCount: Int
    let totalDistanceMeters: Double
    let referenceDate: Date?
    let latestCoordinate: GeoCoordinate?
}
