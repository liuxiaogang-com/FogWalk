import Foundation

// The runner compiles this with the production Roadbook and RoadbookJourney models.
// This coordinate DTO is only needed for RoadbookPoint.geo; no navigation math is mocked.
struct GeoCoordinate { let latitude: Double; let longitude: Double }

@main
enum NavigationJourneyChecks {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let course = RoadbookCourse(points: [.init(latitude: 34, longitude: 113), .init(latitude: 34.02, longitude: 113)])
        var trip = RoadbookJourney(); trip.begin(at: start)
        for i in 0...10 {
            let meters = Double(i) * 50, time = start.addingTimeInterval(Double(i) * 10)
            precondition(trip.append(course.point(at: meters), at: time, accuracy: 5, matchedMeters: meters, course: course))
            trip.updateClock(time)
        }
        precondition(abs(trip.distance - 500) < 1)
        precondition(abs(trip.remainingSeconds(for: 500)! - 100) < 1)
        trip.updateClock(start.addingTimeInterval(160))
        precondition(abs(trip.remainingSeconds(for: 500)! - 160) < 1)
        print("PASS: average ETA uses actual mileage and includes stationary time")

        var restored = try JSONDecoder().decode(RoadbookJourney.self, from: JSONEncoder().encode(trip))
        restored.resume(at: start.addingTimeInterval(1000))
        restored.updateClock(start.addingTimeInterval(1010))
        precondition(restored.id == trip.id && restored.elapsed == 170)
        _ = restored.append(course.point(at: 1500), at: start.addingTimeInterval(1010), accuracy: 5, matchedMeters: 1500, course: course)
        precondition(abs(restored.distance - 500) < 1 && restored.traceSegments.count == 2)
        let fresh = RoadbookJourney()
        precondition(fresh.id != trip.id && fresh.fixes.isEmpty && fresh.covered.isEmpty && fresh.elapsed == 0)
        precondition(fresh.remainingSeconds(for: 500) == nil)
        print("PASS: resume preserves trip; new start is empty; downtime and GPS gaps are excluded")

        var detour = RoadbookJourney(); detour.begin(at: start)
        let samples: [(RoadbookPoint, Double?)] = [(course.point(at: 0), 0), (course.point(at: 50), 50),
            (.init(latitude: 34.001, longitude: 113.001), nil), (course.point(at: 200), 200), (course.point(at: 250), 250)]
        for (i, sample) in samples.enumerated() {
            _ = detour.append(sample.0, at: start.addingTimeInterval(Double(i) * 10), accuracy: 5, matchedMeters: sample.1, course: course)
        }
        precondition(detour.covered.count == 2 && detour.covered[0].upper == 50 && detour.covered[1].lower == 200)
        precondition(detour.distance > 250 && detour.traceSegments[0].count == 5)
        print("PASS: detours remain visible without marking skipped roadbook sections as covered")

        var bad = RoadbookJourney(); bad.begin(at: start)
        _ = bad.append(course.point(at: 0), at: start, accuracy: 5, matchedMeters: 0, course: course)
        precondition(!bad.append(course.point(at: 1000), at: start.addingTimeInterval(1), accuracy: 5, matchedMeters: 1000, course: course))
        precondition(!bad.append(course.point(at: 50), at: start.addingTimeInterval(10), accuracy: 100, matchedMeters: 50, course: course))
        precondition(bad.append(course.point(at: 60), at: start.addingTimeInterval(11), accuracy: 5, matchedMeters: 60, course: course))
        precondition(bad.distance == 0 && bad.covered.isEmpty && bad.traceSegments.count == 2)
        print("PASS: teleport and inaccurate GPS do not inflate distance or join disconnected segments")

        let bend = RoadbookCourse(points: [.init(latitude: 34, longitude: 113), .init(latitude: 34.001, longitude: 113), .init(latitude: 34.001, longitude: 113.001)])
        var shortcut = RoadbookJourney(); shortcut.begin(at: start)
        _ = shortcut.append(bend.points[0], at: start, accuracy: 5, matchedMeters: 0, course: bend)
        _ = shortcut.append(bend.points[2], at: start.addingTimeInterval(15), accuracy: 5, matchedMeters: bend.length, course: bend)
        precondition(shortcut.covered.isEmpty)
        print("PASS: jumping across a roadbook bend does not paint the bend as travelled")
    }
}
