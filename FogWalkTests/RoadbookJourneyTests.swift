import XCTest
import CoreLocation
@testable import FogWalk

final class RoadbookJourneyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var course: RoadbookCourse {
        RoadbookCourse(points: [.init(latitude: 34, longitude: 113), .init(latitude: 34.02, longitude: 113)])
    }
    func testAverageEstimateSurvivesStopAndUsesElapsedTime() throws {
        var trip = RoadbookJourney(); trip.begin(at: start)
        for index in 0...10 {
            let meters = Double(index) * 50, date = start.addingTimeInterval(Double(index) * 10)
            XCTAssertTrue(trip.append(course.point(at: meters), at: date, accuracy: 5, matchedMeters: meters, course: course))
            trip.updateClock(date)
        }
        XCTAssertEqual(trip.distance, 500, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(trip.remainingSeconds(for: 500)), 100, accuracy: 1)
        trip.updateClock(start.addingTimeInterval(160))
        XCTAssertEqual(try XCTUnwrap(trip.remainingSeconds(for: 500)), 160, accuracy: 1)
        XCTAssertFalse(trip.append(course.point(at: 502), at: start.addingTimeInterval(101), accuracy: 5, matchedMeters: 502, course: course))
        XCTAssertEqual(trip.distance, 500, accuracy: 1)
    }
    func testRestoreKeepsTripButExcludesTimeAwayAndDoesNotBridgeGap() throws {
        var trip = RoadbookJourney(); trip.begin(at: start)
        _ = trip.append(course.point(at: 0), at: start, accuracy: 5, matchedMeters: 0, course: course)
        _ = trip.append(course.point(at: 50), at: start.addingTimeInterval(10), accuracy: 5, matchedMeters: 50, course: course)
        trip.updateClock(start.addingTimeInterval(10))
        var restored = try JSONDecoder().decode(RoadbookJourney.self, from: JSONEncoder().encode(trip))
        restored.resume(at: start.addingTimeInterval(1000))
        restored.updateClock(start.addingTimeInterval(1010))
        _ = restored.append(course.point(at: 800), at: start.addingTimeInterval(1010), accuracy: 5, matchedMeters: 800, course: course)
        XCTAssertEqual(restored.id, trip.id)
        XCTAssertEqual(restored.elapsed, 20)
        XCTAssertEqual(restored.distance, 50, accuracy: 1)
        XCTAssertEqual(restored.traceSegments.count, 2)
        XCTAssertEqual(restored.covered.count, 1)
        let fresh = RoadbookJourney()
        XCTAssertNotEqual(fresh.id, trip.id)
        XCTAssertTrue(fresh.fixes.isEmpty); XCTAssertTrue(fresh.covered.isEmpty)
        XCTAssertNil(fresh.remainingSeconds(for: 100))
    }
    func testDetourDoesNotMarkSkippedRouteAsCovered() {
        var trip = RoadbookJourney(); trip.begin(at: start)
        let samples: [(RoadbookPoint, Double?)] = [
            (course.point(at: 0), 0), (course.point(at: 50), 50),
            (.init(latitude: 34.001, longitude: 113.001), nil),
            (course.point(at: 200), 200), (course.point(at: 250), 250)]
        for (index, sample) in samples.enumerated() {
            _ = trip.append(sample.0, at: start.addingTimeInterval(Double(index) * 10), accuracy: 5, matchedMeters: sample.1, course: course)
        }
        XCTAssertEqual(trip.covered.count, 2)
        XCTAssertEqual(trip.covered[0].upper, 50, accuracy: 1)
        XCTAssertEqual(trip.covered[1].lower, 200, accuracy: 1)
        XCTAssertGreaterThan(trip.distance, 250)
        XCTAssertEqual(trip.traceSegments[0].count, 5)
    }
    func testBadFixAndTeleportNeverAddMileageOrBridgeCoverage() {
        var trip = RoadbookJourney(); trip.begin(at: start)
        _ = trip.append(course.point(at: 0), at: start, accuracy: 5, matchedMeters: 0, course: course)
        XCTAssertFalse(trip.append(course.point(at: 1000), at: start.addingTimeInterval(1), accuracy: 5, matchedMeters: 1000, course: course))
        XCTAssertFalse(trip.append(course.point(at: 50), at: start.addingTimeInterval(10), accuracy: 100, matchedMeters: 50, course: course))
        XCTAssertTrue(trip.append(course.point(at: 60), at: start.addingTimeInterval(11), accuracy: 5, matchedMeters: 60, course: course))
        XCTAssertEqual(trip.distance, 0)
        XCTAssertTrue(trip.covered.isEmpty)
        XCTAssertEqual(trip.traceSegments.count, 2)
    }

    @MainActor
    func testNavigationWritesPermanentFootprintsButRestartHasEmptyTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let store = RecordingStore(baseDirectory: root.appendingPathComponent("permanent"))
        let recorder = LocationManager(manager: NavigationRecordingSensorStub(), preferences: preferences, recordingStore: store)
        let nav = RoadbookNavigation(directory: root, usesLiveSensors: false, recorder: recorder)
        let book = Roadbook(id: UUID(), name: "test", importedAt: Date(), fingerprint: "test", points: course.points, waypoints: [], isLoop: false)
        let manager = CLLocationManager(), now = Date()
        func fix(_ meters: Double, _ age: Double) -> CLLocation {
            CLLocation(coordinate: course.point(at: meters).geo.clCoordinate, altitude: 0, horizontalAccuracy: 5,
                       verticalAccuracy: 5, course: 0, speed: 5, timestamp: now.addingTimeInterval(age))
        }
        nav.start(book)
        let firstID = nav.journey.id
        nav.locationManager(manager, didUpdateLocations: [fix(0, -8), fix(50, -3)])
        nav.checkpoint()
        try await recorder.finishPendingWrites()
        XCTAssertFalse(recorder.wantsRecording)
        XCTAssertFalse(preferences.bool(forKey: "recording-enabled-v1"))
        let firstBatch = try await store.read()
        XCTAssertEqual(firstBatch.points.count, 2)
        XCTAssertEqual(nav.journey.fixes.count, 2)
        let restored = RoadbookNavigation(directory: root, usesLiveSensors: false)
        restored.resume()
        XCTAssertEqual(restored.journey.id, firstID)
        XCTAssertEqual(restored.journey.fixes.count, 2)
        restored.end()
        nav.start(book)
        XCTAssertNotEqual(nav.journey.id, firstID)
        XCTAssertEqual(nav.progress, 0)
        XCTAssertTrue(nav.journey.fixes.isEmpty); XCTAssertTrue(nav.journey.covered.isEmpty)
        XCTAssertEqual(nav.journey.elapsed, 0)
        let retained = try await store.read()
        XCTAssertEqual(retained.points.count, 2)
        nav.end()
        XCTAssertNil(recorder.navigationRecordingID)
        nav.start(book, preview: true)
        XCTAssertNil(recorder.navigationRecordingID)
        nav.end()
        let afterPreview = try await store.read()
        XCTAssertEqual(afterPreview.points.count, 2)
    }

    @MainActor
    func testNavigationOwnershipKeepsManualRecordingAndRejectsOldSessionWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(baseDirectory: root)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let recorder = LocationManager(manager: NavigationRecordingSensorStub(), preferences: preferences, recordingStore: store)
        recorder.startRecording()
        let oldID = UUID(), newID = UUID()
        recorder.beginNavigationRecording(oldID); recorder.beginNavigationRecording(newID)
        recorder.endNavigationRecording(oldID)
        XCTAssertEqual(recorder.navigationRecordingID, newID)
        let fix = CLLocation(coordinate: course.points[0].geo.clCoordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        recorder.locationManager(CLLocationManager(), didUpdateLocations: [fix])
        let point = TrackPoint(id: 0, timestamp: fix.timestamp, coordinate: course.points[0].geo, horizontalAccuracy: 5, speed: 0, altitude: 0, source: .recordedDevice)
        recorder.recordNavigationPoint(point, sessionID: oldID)
        recorder.recordNavigationPoint(point, sessionID: newID)
        try await recorder.finishPendingWrites()
        let batch = try await store.read()
        XCTAssertEqual(batch.points.count, 1)
        recorder.endNavigationRecording(newID)
        XCTAssertTrue(recorder.wantsRecording); XCTAssertTrue(recorder.isRecording)
        recorder.stopRecording()
    }
}

private final class NavigationRecordingSensorStub: CLLocationManager {
    override var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    override func startUpdatingLocation() {}
    override func stopUpdatingLocation() {}
    override func startMonitoringSignificantLocationChanges() {}
    override func stopMonitoringSignificantLocationChanges() {}
    override func startMonitoringVisits() {}
    override func stopMonitoringVisits() {}
    override func requestLocation() {}
}
