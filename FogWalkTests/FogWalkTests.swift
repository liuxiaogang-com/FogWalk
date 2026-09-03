import XCTest
import MapKit
@testable import FogWalk

final class FogWalkTests: XCTestCase {
    func testConnectionRulesAcceptNearbyRecentPoints() {
        let first = point(time: 1_700_000_000, latitude: 34.7400, longitude: 113.6950, accuracy: 30)
        let second = point(time: 1_700_000_060, latitude: 34.7405, longitude: 113.6955, accuracy: 35, id: 2)
        XCTAssertTrue(TrackProcessor.canConnect(first, second))
    }

    func testConnectionRulesRejectLongJump() {
        let first = point(time: 1_700_000_000, latitude: 34.7400, longitude: 113.6950, accuracy: 30)
        let second = point(time: 1_700_000_060, latitude: 34.7500, longitude: 113.7050, accuracy: 35, id: 2)
        XCTAssertFalse(TrackProcessor.canConnect(first, second))
    }

    func testConnectionRulesRejectPoorAccuracy() {
        let first = point(time: 1_700_000_000, latitude: 34.7400, longitude: 113.6950, accuracy: 150)
        let second = point(time: 1_700_000_060, latitude: 34.7405, longitude: 113.6955, accuracy: 35, id: 2)
        XCTAssertFalse(TrackProcessor.canConnect(first, second))
    }

    func testFullDemoImportParsesAndDeduplicatesAllSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let demo = root.appendingPathComponent("demodata", isDirectory: true)
        let dataset = try TrackDataLoader.load(
            urls: .init(
                recordedCSV: demo.appendingPathComponent("backUpData-all.csv"),
                photoCSV: demo.appendingPathComponent("backUpPhotoData.csv"),
                gpx: demo.appendingPathComponent("backUpData-all.gpx")
            )
        )

        XCTAssertEqual(dataset.summary.recordedCSVCount, 150_664)
        XCTAssertEqual(dataset.summary.photoCSVCount, 3_519)
        XCTAssertEqual(dataset.summary.gpxCount, 150_664)
        XCTAssertEqual(dataset.summary.duplicateCount, 150_664)
        XCTAssertEqual(dataset.summary.uniqueCount, 154_183)
        XCTAssertEqual(dataset.points.count, dataset.summary.uniqueCount)

        let archiveData = try TrackArchiveCodec.encode(dataset)
        let restored = try TrackArchiveCodec.decode(archiveData)
        XCTAssertEqual(restored.summary, dataset.summary)
        XCTAssertEqual(restored.points.count, dataset.points.count)
        XCTAssertEqual(restored.points.first, dataset.points.first)
        XCTAssertEqual(restored.points.last, dataset.points.last)
    }

    func testPersistentImportSurvivesRelaunchAndDuplicateImport() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let csvURL = temporaryDirectory.appendingPathComponent("backUpData-all.csv")
        let csv = """
        dataTime,longitude,latitude,accuracy,speed,altitude
        1700000000,113.695000,34.740000,20,1,80
        1700000060,113.695500,34.740500,20,1,81
        """
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let firstImport = try TrackDataLoader.importFiles(urls: [csvURL], existing: nil)
        let repeatedImport = try TrackDataLoader.importFiles(urls: [csvURL], existing: firstImport)
        XCTAssertEqual(firstImport.summary.uniqueCount, 2)
        XCTAssertEqual(repeatedImport.summary.uniqueCount, 2)
        XCTAssertEqual(repeatedImport.summary.duplicateCount, 2)

        let store = TrackDataStore(baseDirectory: temporaryDirectory)
        try await store.save(repeatedImport)
        let restored = try await store.load()
        XCTAssertEqual(restored?.summary, repeatedImport.summary)
        XCTAssertEqual(restored?.points, repeatedImport.points)
    }

    func testPhotoPointNeverFormsContinuousTrack() {
        let first = point(
            time: 1_700_000_000,
            latitude: 34.7400,
            longitude: 113.6950,
            accuracy: 0,
            source: .photoCSV
        )
        let second = point(time: 1_700_000_020, latitude: 34.7401, longitude: 113.6951, accuracy: 20, id: 2)
        XCTAssertFalse(TrackProcessor.canConnect(first, second))
    }

    func testExplorationGridUsesFiftyMeterVisitedRadius() {
        let origin = GeoCoordinate(latitude: 34.7400, longitude: 113.7000)
        let grid = ExplorationGrid(coordinates: [origin])
        let near = GeoCoordinate(latitude: 34.7400, longitude: 113.7004)
        let far = GeoCoordinate(latitude: 34.7400, longitude: 113.7012)

        XCTAssertTrue(grid.isExplored(near), "A point roughly 37 m away should be explored")
        XCTAssertFalse(grid.isExplored(far), "A point roughly 110 m away should remain unknown")
        XCTAssertGreaterThan(grid.noveltyRatio(around: far), 0.5)
    }

    func testExplorationGridFillsTrustedSegmentBetweenSamples() {
        let first = point(time: 1_700_000_000, latitude: 34.7400, longitude: 113.7000, accuracy: 20)
        let second = point(
            time: 1_700_000_120,
            latitude: 34.7400,
            longitude: 113.7020,
            accuracy: 20,
            id: 2
        )
        let midpoint = ChinaCoordinateTransform.mapCoordinate(
            for: GeoCoordinate(latitude: 34.7400, longitude: 113.7010)
        )

        XCTAssertTrue(TrackProcessor.canConnect(first, second))
        XCTAssertTrue(ExplorationGrid(points: [first, second]).isExplored(midpoint))
    }

    func testTodayPresentationHasVisiblePathsNearLatestPoint() throws {
        let dataset = try loadFullDataset()
        let presentation = TrackProcessor.makePresentation(
            dataset: dataset,
            filter: .today,
            revision: 1
        )
        XCTAssertEqual(presentation.visiblePointCount, 108)
        XCTAssertFalse(presentation.segments.isEmpty)
        guard let latest = presentation.latestCoordinate else {
            return XCTFail("Missing latest coordinate")
        }
        let overlay = ExplorationOverlay(presentation: presentation, showFog: true, showTrack: true)
        let center = MKMapPoint(latest.clCoordinate)
        let width = 5_500 * MKMapPointsPerMeterAtLatitude(latest.latitude)
        let visibleRect = MKMapRect(
            x: center.x - width / 2,
            y: center.y - width / 2,
            width: width,
            height: width
        )
        XCTAssertGreaterThan(overlay.paths.filter { $0.bounds.intersects(visibleRect) }.count, 0)
    }

    func testChinaMapCoordinateCorrectionMovesImportedGPSOnlyInsideMainland() {
        let zhengzhou = GeoCoordinate(latitude: 34.739933, longitude: 113.695493)
        let corrected = ChinaCoordinateTransform.mapCoordinate(for: zhengzhou)
        let correctionDistance = zhengzhou.location.distance(from: corrected.location)
        XCTAssertGreaterThan(correctionDistance, 400)
        XCTAssertLessThan(correctionDistance, 800)

        let london = GeoCoordinate(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(ChinaCoordinateTransform.mapCoordinate(for: london), london)
    }

    func testFamiliarCafeAndClearRestaurantNamesReceiveHigherPriority() {
        XCTAssertGreaterThan(
            ExploreCategory.cafe.placePriority(name: "瑞幸咖啡（中原万达店）"),
            ExploreCategory.cafe.placePriority(name: "某某生活空间")
        )
        XCTAssertGreaterThan(
            ExploreCategory.food.placePriority(name: "老城区烩面馆"),
            ExploreCategory.food.placePriority(name: "某某生活空间")
        )
    }

    @MainActor
    func testLoopPlannerDoesNotReturnFakeLoop() async {
        let startPoint = point(
            time: 1_700_000_000,
            latitude: 34.7399,
            longitude: 113.6955,
            accuracy: 20
        )
        do {
            _ = try await ExplorePlanner().recommendations(
                start: startPoint.coordinate,
                mode: .loop,
                minutes: 30,
                travelMode: .walking,
                category: .any,
                explorationGrid: ExplorationGrid(points: [startPoint])
            )
            XCTFail("A fake loop recommendation must not be returned")
        } catch ExplorePlannerError.loopTemporarilyUnavailable {
            // Expected until a real multi-leg route engine exists.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func point(
        time: TimeInterval,
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        source: TrackSource = .recordedCSV,
        id: Int64 = 1
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            timestamp: Date(timeIntervalSince1970: time),
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            horizontalAccuracy: accuracy,
            speed: -1,
            altitude: 0,
            source: source
        )
    }

    private func loadFullDataset() throws -> TrackDataset {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let demo = root.appendingPathComponent("demodata", isDirectory: true)
        return try TrackDataLoader.load(
            urls: .init(
                recordedCSV: demo.appendingPathComponent("backUpData-all.csv"),
                photoCSV: demo.appendingPathComponent("backUpPhotoData.csv"),
                gpx: demo.appendingPathComponent("backUpData-all.gpx")
            )
        )
    }
}
