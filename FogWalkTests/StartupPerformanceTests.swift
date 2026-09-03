import XCTest
@testable import FogWalk

final class StartupPerformanceTests: XCTestCase {
    private func sampleDataset() -> TrackDataset {
        let points = (0..<20).map { index in
            TrackPoint(id: Int64(index), timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
                       coordinate: GeoCoordinate(latitude: 31.23, longitude: 121.47 + Double(index) * 0.0001),
                       horizontalAccuracy: 20, speed: 1, altitude: 0, source: .recordedCSV)
        }
        return TrackDataset(points: points, summary: ImportSummary(
            recordedCSVCount: points.count, photoCSVCount: 0, gpxCount: 0, duplicateCount: 0,
            uniqueCount: points.count, earliestDate: points.first?.timestamp, latestDate: points.last?.timestamp
        ))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPackedCoordinatesAreLosslessAndRejectInvalidBytes() throws {
        let coordinates = sampleDataset().points.map(\.coordinate)
        XCTAssertEqual(try PackedCoordinates.decode(PackedCoordinates.encode(coordinates)), coordinates)
        XCTAssertThrowsError(try PackedCoordinates.decode(Data([0, 1, 2])))
        let invalid = [GeoCoordinate(latitude: .nan, longitude: 0)]
        XCTAssertThrowsError(try PackedCoordinates.decode(PackedCoordinates.encode(invalid)))
    }

    func testSnapshotRestoresGridAndEveryDateFilterWithoutChangingGeometry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrackDataStore(baseDirectory: root)
        let data = sampleDataset()
        try await store.save(data)
        let snapshot = StartupSnapshot.build(dataset: data)
        try await store.saveStartup(snapshot)
        let cached = await store.loadStartup()
        let restored = try XCTUnwrap(cached)
        XCTAssertEqual(restored.summary, data.summary)
        for point in data.points {
            let coordinate = ChinaCoordinateTransform.mapCoordinate(for: point.coordinate)
            XCTAssertEqual(restored.grid.isExplored(coordinate), snapshot.grid.isExplored(coordinate))
        }
        let far = GeoCoordinate(latitude: 0, longitude: 0)
        XCTAssertFalse(restored.grid.isExplored(far))
        for filter in TrackTimeFilter.allCases {
            let expected = TrackProcessor.makePresentation(dataset: data, filter: filter, revision: 1)
            let actual = try XCTUnwrap(restored.presentations[filter])
            XCTAssertEqual(actual.visiblePointCount, expected.visiblePointCount)
            XCTAssertEqual(actual.totalDistanceMeters, expected.totalDistanceMeters)
            XCTAssertEqual(actual.latestCoordinate, expected.latestCoordinate)
            XCTAssertEqual(actual.isolatedPoints, expected.isolatedPoints)
            XCTAssertEqual(actual.segments.map(\.coordinates), expected.segments.map(\.coordinates))
        }
    }

    func testCacheMissCorruptionVersionAndAtomicArchiveReplacementAreSafe() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrackDataStore(baseDirectory: root)
        let emptyCache = await store.loadStartup()
        XCTAssertNil(emptyCache)
        let data = sampleDataset()
        try await store.save(data)
        let snapshot = StartupSnapshot.build(dataset: data)
        try await store.saveStartup(snapshot)
        try Data("damaged cache".utf8).write(to: root.appendingPathComponent("startup-v1.cache"))
        let brokenCache = await store.loadStartup()
        XCTAssertNil(brokenCache)
        let original = try await store.load()
        XCTAssertEqual(original?.points, data.points)
        let incompatible = StartupSnapshot(version: -1, calendarIdentifier: snapshot.calendarIdentifier,
            timeZoneIdentifier: snapshot.timeZoneIdentifier, summary: snapshot.summary,
            grid: snapshot.grid, presentations: snapshot.presentations)
        try await store.saveStartup(incompatible)
        let oldVersion = await store.loadStartup()
        XCTAssertNil(oldVersion)
        let wrongZone = StartupSnapshot(version: StartupSnapshot.schemaVersion, calendarIdentifier: snapshot.calendarIdentifier,
            timeZoneIdentifier: "invalid/timezone", summary: snapshot.summary,
            grid: snapshot.grid, presentations: snapshot.presentations)
        try await store.saveStartup(wrongZone)
        let zoneCache = await store.loadStartup()
        XCTAssertNil(zoneCache)
        try await store.saveStartup(snapshot)
        try await store.save(data) // same-size/same-content atomic replacement still invalidates cache
        let staleCache = await store.loadStartup()
        XCTAssertNil(staleCache)
    }

    @MainActor
    func testCacheOnlyLaunchLazyExportAndDuplicateImportPreserveAllPoints() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrackDataStore(baseDirectory: root)
        let data = sampleDataset()
        try await store.save(data)
        try await store.saveStartup(StartupSnapshot.build(dataset: data))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(store: store, preferences: defaults)
        model.loadStoredDataIfNeeded()
        for _ in 0..<500 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasData)
        XCTAssertNil(model.dataset, "Fast launch must not read raw archive")
        model.selectFilter(.lifetime)
        XCTAssertEqual(model.presentation.visiblePointCount, data.points.count)
        let export = await model.makeExportData()
        XCTAssertEqual(try TrackArchiveCodec.decode(XCTUnwrap(export)).points, data.points)

        let second = AppModel(store: store, preferences: defaults)
        second.loadStoredDataIfNeeded()
        for _ in 0..<500 where second.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let backup = root.appendingPathComponent("duplicate.fogwalk")
        try TrackArchiveCodec.encode(data).write(to: backup)
        second.importFiles([backup])
        for _ in 0..<500 where second.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(second.isImporting)
        XCTAssertEqual(second.dataset?.points.count, data.points.count)
        let onDisk = try await store.load()
        XCTAssertEqual(onDisk?.points.count, data.points.count)
    }

    @MainActor
    func testMissingArchiveCannotBeOverwrittenFromCacheOnlySession() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrackDataStore(baseDirectory: root)
        let data = sampleDataset()
        try await store.save(data)
        try await store.saveStartup(StartupSnapshot.build(dataset: data))
        let model = AppModel(store: store, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        model.loadStoredDataIfNeeded()
        for _ in 0..<500 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        // Simulate a disk failure after the cache-only launch, not a real user's archive.
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.fogwalk"))
        let backup = root.appendingPathComponent("new.fogwalk")
        try TrackArchiveCodec.encode(data).write(to: backup)
        model.importFiles([backup])
        for _ in 0..<500 where model.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.noticeTitle, "导入失败")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.fogwalk").path))
    }

    @MainActor
    func testRecommendationCannotRunBeforeExplorationRestored() {
        let model = AppModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        model.searchDestinations()
        XCTAssertFalse(model.isGeneratingRecommendations)
        XCTAssertTrue(model.exploreErrorMessage?.contains("恢复") == true)
    }

    func testFullLibraryStartupBenchmark() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("demodata")
        let data = try TrackDataLoader.load(urls: .init(
            recordedCSV: source.appendingPathComponent("backUpData-all.csv"),
            photoCSV: source.appendingPathComponent("backUpPhotoData.csv"),
            gpx: source.appendingPathComponent("backUpData-all.gpx")))
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrackDataStore(baseDirectory: root)
        try await store.save(data)
        let begin = CFAbsoluteTimeGetCurrent()
        let loaded = try await store.load()
        let dataset = try XCTUnwrap(loaded)
        _ = ExplorationGrid(points: dataset.points)
        _ = TrackProcessor.makePresentation(dataset: dataset, filter: .lifetime, revision: 1)
        _ = TrackProcessor.makePresentation(dataset: dataset, filter: .today, revision: 2)
        let oldSeconds = CFAbsoluteTimeGetCurrent() - begin
        let buildStart = CFAbsoluteTimeGetCurrent()
        try await store.saveStartup(StartupSnapshot.build(dataset: data))
        let migrationSeconds = CFAbsoluteTimeGetCurrent() - buildStart
        var samples = [Double]()
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            let cached = await store.loadStartup()
            samples.append(CFAbsoluteTimeGetCurrent() - start)
            XCTAssertEqual(cached?.summary.uniqueCount, 154_183)
            XCTAssertEqual(cached?.presentations[.lifetime]?.visiblePointCount, data.points.count)
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("startup-v1.cache").path)[.size]!
        print("STARTUP_BENCHMARK points=\(data.points.count) old=\(oldSeconds)s migration=\(migrationSeconds)s cached=\(samples)s cacheBytes=\(bytes)")
        XCTAssertLessThan(samples.sorted()[1], oldSeconds, "Cache restore should beat full decode and rebuild")
    }
}
