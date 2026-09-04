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

    func testDayPresentationHasVisiblePathsAtExplicitHistoricalDate() throws {
        let dataset = try loadFullDataset()
        let presentation = TrackProcessor.makePresentation(
            dataset: dataset,
            filter: .today,
            revision: 1,
            now: try XCTUnwrap(dataset.summary.latestDate)
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

    func testHistoricalDataIsNotDisplayedAsTodayOrCurrentMonth() {
        let old = point(time: 1_700_000_000, latitude: 34.74, longitude: 113.69, accuracy: 20)
        let data = TrackDataset(points: [old], summary: ImportSummary(recordedCSVCount: 1,
            photoCSVCount: 0, gpxCount: 0, duplicateCount: 0, uniqueCount: 1,
            earliestDate: old.timestamp, latestDate: old.timestamp))
        let now = old.timestamp.addingTimeInterval(60 * 60 * 24 * 60)
        for filter in [TrackTimeFilter.today, .sevenDays, .month] {
            XCTAssertEqual(TrackProcessor.makePresentation(dataset: data, filter: filter, revision: 1, now: now).visiblePointCount, 0)
        }
        XCTAssertEqual(TrackProcessor.makePresentation(dataset: data, filter: .lifetime, revision: 1, now: now).visiblePointCount, 1)
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

    func testStaleSearchGenerationCannotPublishAfterCancelOrOptionChange() {
        var generation = SearchGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.accepts(first))
        let second = generation.advance()
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
    }

    func testUnverifiedRouteNeverClaimsZeroPercentOrRoadDistance() {
        let result = recommendation("测试终点", longitude: 121.47, verified: false)
        XCTAssertEqual(result.noveltyText, "路线待确认")
        XCTAssertTrue(result.timeText.hasPrefix("估算约"))
        XCTAssertTrue(result.distanceText.hasPrefix("直线"))
        XCTAssertFalse(result.noveltyText.contains("0%"))
    }

    @MainActor
    func testBudgetUsesActualSecondsAndDoesNotRoundOvertimeDown() {
        XCTAssertTrue(ExplorePlanner.fitsBudget(seconds: 1_800, minutes: 30))
        XCTAssertFalse(ExplorePlanner.fitsBudget(seconds: 1_801, minutes: 30))
        XCTAssertFalse(ExplorePlanner.fitsBudget(seconds: .infinity, minutes: 30))
        XCTAssertFalse(ExplorePlanner.fitsBudget(seconds: -1, minutes: 30))
    }

    @MainActor
    func testChangedOptionsInvalidateResultsAndPersistWithoutLocations() throws {
        let suite = "FogWalkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: defaults)
        let old = recommendation("旧地点", longitude: 121.47)
        model.recommendations = [old]
        model.selectedRecommendationID = old.id
        model.exploreOptions.minutes = 45
        model.exploreOptions.category = .tea
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertNil(model.selectedRecommendationID)
        XCTAssertFalse(model.isGeneratingRecommendations)
        let restored = AppModel(preferences: defaults)
        XCTAssertEqual(restored.exploreOptions.minutes, 45)
        XCTAssertEqual(restored.exploreOptions.category, .tea)
        XCTAssertTrue(restored.recommendations.isEmpty)
    }

    @MainActor
    func testNewBatchExcludesSeenPlacesAndPrioritizesDifferentNames() {
        let first = recommendation("同品牌（甲店）", longitude: 121.47)
        let sameBrand = recommendation("同品牌（乙店）", longitude: 121.48)
        let other = recommendation("独立咖啡", longitude: 121.50)
        let result = ExplorePlanner.diverseResults([first, sameBrand, other], excluding: [])
        XCTAssertEqual(result.map(\.title), [first.title, other.title, sameBrand.title])
        let newBatch = ExplorePlanner.diverseResults([first, sameBrand, other], excluding: [first.stableKey])
        XCTAssertFalse(newBatch.contains(where: { $0.stableKey == first.stableKey }))
    }

    func testCoffeeAndTeaAreDistinctAndIndependentCafeNotPenalized() {
        XCTAssertFalse(ExploreCategory.cafe.searchQueries.contains("蜜雪冰城"))
        XCTAssertTrue(ExploreCategory.tea.searchQueries.contains("蜜雪冰城"))
        XCTAssertEqual(ExploreCategory.cafe.placePriority(name: "小巷咖啡"), ExploreCategory.cafe.placePriority(name: "瑞幸咖啡"))
    }

    @MainActor
    func testRouteFailureNeverProducesStraightLineRecommendations() {
        let estimate = recommendation("未验证地点", longitude: 121.48, verified: false)
        XCTAssertThrowsError(try ExplorePlanner.validatedResults([estimate], unresolvedCount: 1,
            overBudgetCount: 0, excluding: [])) { error in
                guard case ExplorePlannerError.routeServiceUnavailable = error else { return XCTFail("Wrong failure") }
            }
        XCTAssertThrowsError(try ExplorePlanner.validatedResults([], unresolvedCount: 0,
            overBudgetCount: 2, excluding: [])) { error in
                guard case ExplorePlannerError.noRouteWithinBudget = error else { return XCTFail("Wrong budget failure") }
            }
    }

    private func recommendation(_ title: String, longitude: Double, verified: Bool = true) -> ExploreRecommendation {
        ExploreRecommendation(title: title, subtitle: "测试", coordinate: GeoCoordinate(latitude: 31.23, longitude: longitude),
            estimatedMinutes: 20, distanceMeters: 1_000, routeCoordinates: [], routeNoveltyRatio: 0,
            destinationNoveltyRatio: 1, mapItem: nil, isRouteVerified: verified)
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
