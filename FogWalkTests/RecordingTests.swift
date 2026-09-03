import XCTest
import CoreLocation
@testable import FogWalk

final class RecordingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func point(_ seconds: Double = 0, meters: Double = 0, accuracy: Double = 10, speed: Double = 1) -> TrackPoint {
        TrackPoint(id: 0, timestamp: now.addingTimeInterval(seconds),
                   coordinate: GeoCoordinate(latitude: 31.23 + meters / 111_000, longitude: 121.47),
                   horizontalAccuracy: accuracy, speed: speed, altitude: 0, source: .recordedDevice)
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testModeSamplingAccuracyAndDistanceThresholds() {
        var normal = RecordingPolicy()
        var saver = RecordingPolicy()
        XCTAssertTrue(normal.accept(point(), mode: .normal, now: now))
        XCTAssertTrue(saver.accept(point(), mode: .saver, now: now))
        XCTAssertTrue(normal.accept(point(10, meters: 20), mode: .normal, now: now.addingTimeInterval(10)))
        XCTAssertFalse(saver.accept(point(10, meters: 20), mode: .saver, now: now.addingTimeInterval(10)))
        XCTAssertTrue(saver.accept(point(30, meters: 70), mode: .saver, now: now.addingTimeInterval(30)))
        XCTAssertFalse(normal.accept(point(40, meters: 90, accuracy: 80), mode: .normal, now: now.addingTimeInterval(40)))
        XCTAssertFalse(saver.accept(point(60, meters: 150, accuracy: 110), mode: .saver, now: now.addingTimeInterval(60)))
    }

    func testRejectsStaleDuplicateJitterAndImpossibleJump() {
        var policy = RecordingPolicy()
        XCTAssertFalse(policy.accept(point(-60), mode: .normal, now: now))
        XCTAssertTrue(policy.accept(point(), mode: .normal, now: now))
        XCTAssertFalse(policy.accept(point(), mode: .normal, now: now))
        XCTAssertFalse(policy.accept(point(10, meters: 2), mode: .normal, now: now.addingTimeInterval(10)))
        XCTAssertFalse(policy.accept(point(11, meters: 5_000), mode: .normal, now: now.addingTimeInterval(11)))
        XCTAssertTrue(policy.accept(point(20, meters: 30), mode: .normal, now: now.addingTimeInterval(20)))
    }

    func testStationaryHysteresisAndMotionRecovery() {
        var policy = RecordingPolicy()
        policy.updateMotion(.stationary, confident: false, now: now)
        XCTAssertFalse(policy.isResting(mode: .saver, now: now.addingTimeInterval(300)))
        policy.updateMotion(.stationary, confident: true, now: now)
        XCTAssertFalse(policy.isResting(mode: .normal, now: now.addingTimeInterval(119)))
        XCTAssertTrue(policy.isResting(mode: .normal, now: now.addingTimeInterval(120)))
        XCTAssertTrue(policy.isResting(mode: .saver, now: now.addingTimeInterval(90)))
        policy.updateMotion(.walking, confident: true, now: now.addingTimeInterval(121))
        XCTAssertFalse(policy.isResting(mode: .saver, now: now.addingTimeInterval(200)))
    }

    func testDelayedRecordingDeliveryIsNotTreatedAsFreshCurrentLocation() {
        var policy = RecordingPolicy()
        XCTAssertFalse(policy.accept(point(-90), mode: .normal, now: now))
        XCTAssertTrue(policy.accept(point(-90), mode: .normal, now: now, maximumAge: 300))
        XCTAssertFalse(policy.accept(point(-400), mode: .normal, now: now, maximumAge: 300))
    }

    func testSQLiteRelaunchDedupAndCheckpoint() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(baseDirectory: root)
        let input = [point(), point(30, meters: 70)]
        let inserted = try await store.append(input, mode: .normal, context: "background")
        XCTAssertEqual(inserted, 2)
        let repeated = try await store.append(input, mode: .saver, context: "foreground")
        XCTAssertEqual(repeated, 0)
        let batch = try await RecordingStore(baseDirectory: root).read()
        XCTAssertEqual(batch.points.map(\.coordinate), input.map(\.coordinate))
        let remainder = try await store.read(after: batch.checkpoint)
        XCTAssertTrue(remainder.points.isEmpty)
        let foreign = try await store.read(after: RecordingCheckpoint(journalID: "another-phone", rowID: 99_999))
        XCTAssertEqual(foreign.points.count, 2)
        let merged = TrackDataLoader.merging(batch, into: nil)
        let restored = try TrackArchiveCodec.decode(TrackArchiveCodec.encode(merged))
        XCTAssertEqual(restored.points.count, 2)
        XCTAssertEqual(restored.summary.recordingCheckpoint, batch.checkpoint)
        XCTAssertEqual(restored.summary.recordedDeviceCount, 2)
    }

    func testOlderArchiveIsStillReadable() throws {
        let data = TrackDataLoader.merging(RecordedBatch(checkpoint: .init(journalID: "test", rowID: 1), points: [point()]), into: nil)
        let encoder = PropertyListEncoder()
        let encoded = try encoder.encode(TrackArchive(version: 1, exportedAt: now, dataset: data))
        XCTAssertEqual(try TrackArchiveCodec.decode(encoded).points.count, 1)
    }

    func testIncrementalGridKeepsOriginalAndRevealsNewTrustedSegment() {
        let old = GeoCoordinate(latitude: 31.24, longitude: 121.48)
        let base = ExplorationGrid(coordinates: [old])
        let newer = [point(), point(60, meters: 150)]
        let grid = base.incorporating(newer)
        XCTAssertTrue(grid.isExplored(old))
        XCTAssertTrue(grid.isExplored(ChinaCoordinateTransform.mapCoordinate(for: point(30, meters: 75).coordinate)))
        XCTAssertFalse(base.isExplored(ChinaCoordinateTransform.mapCoordinate(for: newer[0].coordinate)))
    }

    @MainActor
    func testJournalOnlyRelaunchExportsAndImportCheckpointPreventsDoubleCount() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = RecordingStore(baseDirectory: root.appendingPathComponent("recordings"))
        let archive = TrackDataStore(baseDirectory: root)
        _ = try await journal.append([point(), point(30, meters: 70)], mode: .normal, context: "background")
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(store: archive, preferences: preferences, recordingStore: journal)
        model.loadStoredDataIfNeeded()
        for _ in 0..<500 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.hasData)
        XCTAssertEqual(model.explorationPresentation.visiblePointCount, 2)
        let export = await model.makeExportData()
        let data = try XCTUnwrap(export)
        XCTAssertEqual(try TrackArchiveCodec.decode(data).points.count, 2)
        let backup = root.appendingPathComponent("input.fogwalk")
        try data.write(to: backup)
        model.importFiles([backup])
        for _ in 0..<500 where model.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.explorationPresentation.visiblePointCount, 2)
        let second = AppModel(store: archive, preferences: preferences, recordingStore: journal)
        second.loadStoredDataIfNeeded()
        for _ in 0..<500 where second.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(second.explorationPresentation.visiblePointCount, 2)
        XCTAssertNil(second.dataset, "Recorded history must not disable the fast startup cache")
    }

    @MainActor
    func testLocationCallbacksPersistForForegroundAndBackgroundContexts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(baseDirectory: root)
        let recorder = LocationManager(preferences: UserDefaults(suiteName: UUID().uuidString)!, recordingStore: store)
        guard recorder.authorizationStatus == .authorizedAlways || recorder.authorizationStatus == .authorizedWhenInUse else {
            throw XCTSkip("Run this integration check after granting the simulator test host location access")
        }
        recorder.startRecording()
        defer { recorder.stopRecording() }
        XCTAssertTrue(recorder.isRecording)
        let instant = Date()
        let first = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.23000, longitude: 121.47000),
                               altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                               course: 0, speed: 1, timestamp: instant.addingTimeInterval(-10))
        recorder.locationManager(CLLocationManager(), didUpdateLocations: [first])
        for _ in 0..<200 where recorder.savedPointCount < 1 { try await Task.sleep(for: .milliseconds(10)) }
        recorder.setBackground(true)
        let second = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.23030, longitude: 121.47000),
                                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                course: 0, speed: 1, timestamp: instant)
        recorder.locationManager(CLLocationManager(), didUpdateLocations: [second])
        for _ in 0..<200 where recorder.savedPointCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.savedPointCount, 2)
        let restored = try await RecordingStore(baseDirectory: root).read()
        XCTAssertEqual(restored.points.count, 2)
        XCTAssertEqual(recorder.currentCoordinate?.latitude, 31.23030)
    }
}
