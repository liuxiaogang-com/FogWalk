import Foundation
import CoreLocation

struct TrackProcessor: Sendable {
    static let maximumConnectionInterval: TimeInterval = 5 * 60
    static let maximumConnectionDistance: CLLocationDistance = 300
    static let maximumAcceptedAccuracy: CLLocationAccuracy = 100
    static let maximumPlausibleSpeed: CLLocationSpeed = 65

    static func makePresentation(
        dataset: TrackDataset,
        filter: TrackTimeFilter,
        revision: Int,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> TrackPresentation {
        guard let referenceDate = dataset.summary.latestDate else {
            return .empty
        }

        let interval = dateInterval(for: filter, referenceDate: filter == .lifetime ? referenceDate : now, calendar: calendar)
        let visible = dataset.points.filter { interval.contains($0.timestamp) }
        guard !visible.isEmpty else {
            return TrackPresentation(
                revision: revision,
                filter: filter,
                segments: [],
                isolatedPoints: [],
                visiblePointCount: 0,
                totalDistanceMeters: 0,
                referenceDate: referenceDate,
                latestCoordinate: dataset.points.last.map {
                    ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
                }
            )
        }

        var segments = [TrackSegment]()
        var isolated = [GeoCoordinate]()
        var currentCoordinates = [GeoCoordinate]()
        var previous: TrackPoint?
        var distance: CLLocationDistance = 0
        var segmentID = 0

        func flushCurrent() {
            guard !currentCoordinates.isEmpty else { return }
            if currentCoordinates.count == 1 {
                isolated.append(currentCoordinates[0])
            } else {
                segments.append(TrackSegment(id: segmentID, coordinates: currentCoordinates))
                segmentID += 1
            }
            currentCoordinates.removeAll(keepingCapacity: true)
        }

        for point in visible {
            let mapCoordinate = ChinaCoordinateTransform.mapCoordinate(for: point.coordinate)
            if point.source == .photoCSV {
                flushCurrent()
                isolated.append(mapCoordinate)
                previous = nil
                continue
            }

            guard isValidRecordedPoint(point) else {
                flushCurrent()
                previous = nil
                continue
            }

            if let previous, canConnect(previous, point, calendar: calendar) {
                let stepDistance = distanceMeters(from: previous.coordinate, to: point.coordinate)
                if currentCoordinates.isEmpty {
                    currentCoordinates.append(
                        ChinaCoordinateTransform.mapCoordinate(for: previous.coordinate)
                    )
                }
                currentCoordinates.append(mapCoordinate)
                distance += stepDistance
            } else {
                flushCurrent()
                currentCoordinates.append(mapCoordinate)
            }
            previous = point
        }
        flushCurrent()

        return TrackPresentation(
            revision: revision,
            filter: filter,
            segments: segments,
            isolatedPoints: isolated,
            visiblePointCount: visible.count,
            totalDistanceMeters: distance,
            referenceDate: referenceDate,
            latestCoordinate: visible.last.map {
                ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
            } ?? dataset.points.last.map {
                ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
            }
        )
    }

    static func canConnect(
        _ first: TrackPoint,
        _ second: TrackPoint,
        calendar: Calendar = .current
    ) -> Bool {
        guard first.source != .photoCSV,
              second.source != .photoCSV,
              isValidRecordedPoint(first),
              isValidRecordedPoint(second),
              calendar.isDate(first.timestamp, inSameDayAs: second.timestamp) else {
            return false
        }

        let interval = second.timestamp.timeIntervalSince(first.timestamp)
        guard interval > 0, interval <= maximumConnectionInterval else { return false }
        let distance = distanceMeters(from: first.coordinate, to: second.coordinate)
        guard distance <= maximumConnectionDistance else { return false }
        return distance / interval <= maximumPlausibleSpeed
    }

    static func distanceMeters(from first: GeoCoordinate, to second: GeoCoordinate) -> Double {
        first.location.distance(from: second.location)
    }

    private static func isValidRecordedPoint(_ point: TrackPoint) -> Bool {
        point.horizontalAccuracy >= 0 && point.horizontalAccuracy <= maximumAcceptedAccuracy
    }

    private static func dateInterval(
        for filter: TrackTimeFilter,
        referenceDate: Date,
        calendar: Calendar
    ) -> DateInterval {
        let end = referenceDate.addingTimeInterval(1)
        switch filter {
        case .today:
            return DateInterval(start: calendar.startOfDay(for: referenceDate), end: end)
        case .sevenDays:
            let today = calendar.startOfDay(for: referenceDate)
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? .distantPast
            return DateInterval(start: start, end: end)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: referenceDate)
            return DateInterval(start: calendar.date(from: components) ?? .distantPast, end: end)
        case .lifetime:
            return DateInterval(start: .distantPast, end: end)
        }
    }
}
