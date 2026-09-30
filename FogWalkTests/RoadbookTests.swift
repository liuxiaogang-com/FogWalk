import XCTest
import CoreLocation
import MapKit
@testable import FogWalk

@MainActor
final class RoadbookTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let gpx = "<gpx><trk><name>我的路线</name><trkseg><trkpt lat='34.7' lon='113.6'/><trkpt lat='34.71' lon='113.6'/><trkpt lat='34.71' lon='113.61'/></trkseg></trk></gpx>"
    func testCompleteGPXWithExportResidueRecoversAndDeduplicates() throws {
        let root = try directory(), store = RoadbookStore(directory: root)
        let id = try store.importData(Data((gpx + "on=\"113.65\">\n<trkpt><time>2").utf8), name: "residue")
        XCTAssertEqual(store.books[0].points.count, 3)
        XCTAssertNotNil(store.books[0].importWarning)
        XCTAssertEqual(try store.importData(Data(gpx.utf8), name: "clean"), id)
        XCTAssertNotNil(RoadbookStore(directory: root).books[0].importWarning)
    }
    func testIncompleteOrConcatenatedGPXIsNotSilentlyRecovered() throws {
        let store = RoadbookStore(directory: try directory())
        for text in [String(gpx.dropLast(6)), gpx + gpx,
                     gpx.replacingOccurrences(of: "</trkseg>", with: "&broken;</trkseg>"),
                     gpx.replacingOccurrences(of: "gpx", with: "document")] {
            XCTAssertThrowsError(try store.importData(Data(text.utf8), name: "invalid"))
        }
        XCTAssertTrue(store.books.isEmpty)
    }
    func testNamespacedGPX11WithTimeAndElevation() throws {
        let store = RoadbookStore(directory: try directory())
        let xml = "<g:gpx xmlns:g='http://www.topografix.com/GPX/1/1' version='1.1' creator='IGPSPORT'><g:trk><g:trkseg><g:trkpt lat='34.7' lon='113.6'><g:ele>91</g:ele><g:time>2024-08-31T20:41:37Z</g:time></g:trkpt><g:trkpt lat='34.71' lon='113.6'/></g:trkseg></g:trk></g:gpx>"
        _ = try store.importData(Data(xml.utf8), name: "GPX 1.1")
        XCTAssertEqual(store.books.first?.points.count, 2)
        XCTAssertNil(store.books.first?.importWarning)
    }
    func testImportRenameDeleteAndReloadKeepSeparateLibrary() throws {
        let root = try directory(), store = RoadbookStore(directory: root)
        let id = try store.importData(Data(gpx.utf8), name: "fallback")
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books[0].name, "我的路线")
        XCTAssertFalse(store.books[0].isLoop)
        XCTAssertEqual(try store.importData(Data(gpx.utf8), name: "again"), id)
        try store.rename(id, to: "新的名称")
        let reloaded = RoadbookStore(directory: root)
        XCTAssertEqual(reloaded.books[0].name, "新的名称")
        try reloaded.delete(id)
        XCTAssertTrue(RoadbookStore(directory: root).books.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.libraryURL.path))
    }
    func testInvalidOrDisconnectedGPXDoesNotReplaceLibrary() throws {
        let store = RoadbookStore(directory: try directory())
        _ = try store.importData(Data(gpx.utf8), name: "valid")
        let invalid = ["<gpx>", "<gpx><trk><trkseg><trkpt lat='999' lon='1'/></trkseg></trk></gpx>",
            "<gpx><trk><trkseg><trkpt lat='34' lon='113'/></trkseg><trkseg><trkpt lat='35' lon='114'/></trkseg></trk></gpx>"]
        for value in invalid { XCTAssertThrowsError(try store.importData(Data(value.utf8), name: "invalid")) }
        XCTAssertEqual(store.books.count, 1)
    }
    func testCorruptLibraryIsNotOverwritten() throws {
        let root = try directory(), url = root.appendingPathComponent("library-v1.json")
        let original = Data("corrupt".utf8); try original.write(to: url)
        let store = RoadbookStore(directory: root)
        XCTAssertThrowsError(try store.importData(Data(gpx.utf8), name: "new"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testLoopRotationPreservesFullLengthAndEntry() {
        let a = RoadbookPoint(latitude: 34, longitude: 113)
        let b = RoadbookPoint(latitude: 34.01, longitude: 113)
        let c = RoadbookPoint(latitude: 34.01, longitude: 113.01)
        let d = RoadbookPoint(latitude: 34, longitude: 113.01)
        let original = RoadbookCourse(points: [a,b,c,d,a])
        let entry = original.length * 0.37
        let rotated = original.startingLoop(at: entry)
        XCTAssertEqual(rotated.length, original.length, accuracy: 1)
        XCTAssertEqual(rotated.points.first, rotated.points.last)
        XCTAssertLessThan(RoadbookCourse.distance(rotated.points[0], original.point(at: entry)), 0.01)
        XCTAssertEqual(rotated.points[1], c)
    }
    func testTurnRemindersDeduplicateAndAdvanceOnlyAfterCorner() {
        let course = RoadbookCourse(points: [.init(latitude: 34, longitude: 113), .init(latitude: 34.01, longitude: 113), .init(latitude: 34.01, longitude: 113.01)])
        XCTAssertEqual(course.turns.count, 1)
        let turn = course.turns[0]; var alerts = RoadbookAlerts()
        XCTAssertNil(alerts.update(course: course, meters: turn.meters-90, onRoute: false))
        XCTAssertNotNil(alerts.update(course: course, meters: turn.meters-99, onRoute: true))
        XCTAssertNil(alerts.update(course: course, meters: turn.meters-70, onRoute: true))
        XCTAssertNotNil(alerts.update(course: course, meters: turn.meters-49, onRoute: true))
        XCTAssertNil(alerts.update(course: course, meters: turn.meters-20, onRoute: true))
        XCTAssertEqual(course.upcoming(at: turn.meters+5).count, 1)
        XCTAssertTrue(course.upcoming(at: turn.meters+9).isEmpty)
    }
    func testMatchingStaysNearOrderedProgressAtLoopClosure() {
        let a = RoadbookPoint(latitude: 34, longitude: 113)
        let course = RoadbookCourse(points: [a,.init(latitude: 34.01, longitude: 113),.init(latitude: 34.01, longitude: 113.01),.init(latitude: 34, longitude: 113.01),a])
        XCTAssertLessThan(course.match(a, previous: 0).meters, 1)
        XCTAssertGreaterThan(course.match(a, previous: course.length-50).meters, course.length-1)
    }
    func testRealNavigationRequiresOpenStartAndRecoversSavedProgress() throws {
        let root = try directory(), store = RoadbookStore(directory: root)
        _ = try store.importData(Data(gpx.utf8), name: "route")
        let nav = RoadbookNavigation(directory: root, usesLiveSensors: false)
        nav.start(store.books[0]); let manager = CLLocationManager()
        func fix(_ p: RoadbookPoint, age: Double = 0, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: p.geo.clCoordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                       course: 0, speed: 5, timestamp: Date().addingTimeInterval(age))
        }
        nav.locationManager(manager, didUpdateLocations: [fix(nav.course.point(at: 100), age: -12)])
        XCTAssertFalse(nav.session!.entered)
        nav.locationManager(manager, didUpdateLocations: [fix(nav.course.point(at: 0), age: -9)])
        XCTAssertTrue(nav.session!.entered)
        nav.locationManager(manager, didUpdateLocations: [fix(nav.course.point(at: 100), age: -4)])
        XCTAssertEqual(nav.progress, 100, accuracy: 1)
        nav.checkpoint()
        let saved = RoadbookNavigation(directory: root, usesLiveSensors: false)
        XCTAssertNotNil(saved.recoverable)
        saved.resume(); XCTAssertTrue(saved.session!.entered)
        XCTAssertEqual(saved.progress, 100, accuracy: 1)
        nav.locationManager(manager, didUpdateLocations: [fix(nav.course.point(at: 200), accuracy: 100)])
        XCTAssertFalse(nav.onRoute); XCTAssertEqual(nav.progress, 100, accuracy: 1)
        saved.end(); XCTAssertNil(RoadbookNavigation(directory: root, usesLiveSensors: false).recoverable)
        nav.end()
    }
    func testChosenLoopEntryWaitsForExplicitConfirmationAndSurvivesRestart() throws {
        let root = try directory(), store = RoadbookStore(directory: root)
        let data = "<gpx><trk><trkseg><trkpt lat='34' lon='113'/><trkpt lat='34.01' lon='113'/><trkpt lat='34.01' lon='113.01'/><trkpt lat='34' lon='113.01'/><trkpt lat='34' lon='113'/></trkseg></trk></gpx>"
        _ = try store.importData(Data(data.utf8), name: "loop")
        let book = store.books[0], original = RoadbookCourse(points: book.points)
        let selected = original.length * 0.4
        let nav = RoadbookNavigation(directory: root, usesLiveSensors: false)
        nav.start(book, entryMeters: selected)
        XCTAssertTrue(nav.isApproaching)
        XCTAssertLessThan(RoadbookCourse.distance(nav.entryPoint!, original.point(at: selected)), 0.01)
        XCTAssertEqual(nav.course.length, original.length, accuracy: 1)
        let manager = CLLocationManager()
        func fix(_ p: RoadbookPoint, age: Double = 0, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: p.geo.clCoordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: 5, timestamp: Date().addingTimeInterval(age))
        }
        nav.locationManager(manager, didUpdateLocations: [fix(nav.course.point(at: 100), age: -8)])
        nav.confirmLoopStart(); XCTAssertFalse(nav.session!.entered)
        XCTAssertFalse(nav.readyToStartLoop)
        nav.locationManager(manager, didUpdateLocations: [fix(nav.entryPoint!, age: -2)])
        XCTAssertTrue(nav.readyToStartLoop); XCTAssertFalse(nav.session!.entered)
        XCTAssertEqual(nav.progress, 0)
        nav.checkpoint()
        let resumed = RoadbookNavigation(directory: root, usesLiveSensors: false)
        resumed.resume()
        XCTAssertTrue(resumed.isApproaching); XCTAssertFalse(resumed.readyToStartLoop)
        XCTAssertEqual(resumed.session?.entryMeters, selected)
        XCTAssertEqual(resumed.entryPoint, nav.entryPoint)
        resumed.confirmLoopStart(); XCTAssertFalse(resumed.session!.entered)
        resumed.locationManager(manager, didUpdateLocations: [fix(resumed.entryPoint!)])
        resumed.confirmLoopStart()
        XCTAssertTrue(resumed.session!.entered); XCTAssertFalse(resumed.isApproaching)
        XCTAssertEqual(resumed.progress, 0)
        nav.end(); resumed.end()
    }
    func testPoorOrStaleLocationCannotConfirmLoopEntry() throws {
        let root = try directory(), store = RoadbookStore(directory: root)
        _ = try store.importData(Data(gpx.utf8), name: "route")
        var book = store.books[0]; book.isLoop = true
        let nav = RoadbookNavigation(directory: root, usesLiveSensors: false)
        nav.start(book, entryMeters: 100)
        let point = nav.entryPoint!, manager = CLLocationManager()
        let stale = CLLocation(coordinate: point.geo.clCoordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date().addingTimeInterval(-30))
        nav.locationManager(manager, didUpdateLocations: [stale]); nav.confirmLoopStart()
        XCTAssertFalse(nav.readyToStartLoop); XCTAssertFalse(nav.session!.entered)
        let accurate = CLLocation(coordinate: point.geo.clCoordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date().addingTimeInterval(-2))
        nav.locationManager(manager, didUpdateLocations: [accurate])
        XCTAssertTrue(nav.readyToStartLoop)
        let poor = CLLocation(coordinate: point.geo.clCoordinate, altitude: 0, horizontalAccuracy: 120, verticalAccuracy: 5, timestamp: Date())
        nav.locationManager(manager, didUpdateLocations: [poor]); nav.confirmLoopStart()
        XCTAssertFalse(nav.session!.entered); XCTAssertFalse(nav.readyToStartLoop)
        nav.end()
    }
    func testMapCoordinateRoundTripForApproachRoutes() {
        for point in [GeoCoordinate(latitude: 34.75, longitude: 113.65), GeoCoordinate(latitude: 37.77, longitude: -122.42)] {
            let mapped = ChinaCoordinateTransform.mapCoordinate(for: point)
            let recovered = RoadbookNavigation.sourcePoint(mapped.clCoordinate)
            XCTAssertEqual(recovered.latitude, point.latitude, accuracy: 0.000001)
            XCTAssertEqual(recovered.longitude, point.longitude, accuracy: 0.000001)
        }
    }
    func testNavigationMapAllowsGesturesAndKeepsZoomWithLowerAnchor() {
        let p = RoadbookPoint(latitude: 34, longitude: 113)
        let view = RoadbookMapContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        view.layoutIfNeeded()
        var configuration = RoadbookMapView(points: [p,.init(latitude: 34.01, longitude: 113)], position: p, overview: false, positionFraction: 0.72)
        view.update(configuration)
        XCTAssertTrue(view.map.isZoomEnabled); XCTAssertTrue(view.map.isScrollEnabled)
        let before = view.map.camera.centerCoordinateDistance
        configuration.zoomRequest = 1; view.update(configuration)
        let zoomed = view.map.camera.centerCoordinateDistance
        XCTAssertLessThan(zoomed, before * 0.8)
        configuration.position = RoadbookPoint(latitude: 34.0001, longitude: 113)
        view.update(configuration)
        XCTAssertEqual(view.map.camera.centerCoordinateDistance, zoomed, accuracy: 5)
        let screen = view.map.convert(ChinaCoordinateTransform.mapCoordinate(for: configuration.position!.geo).clCoordinate, toPointTo: view.map)
        XCTAssertEqual(screen.y / 650, 0.72, accuracy: 0.04)
    }
    func testHeadingRotatesAroundRiderWithFooterInset() {
        let p = RoadbookPoint(latitude: 34.75, longitude: 113.65)
        let view = RoadbookMapContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.layoutIfNeeded()
        var value = RoadbookMapView(points: [p,.init(latitude: 34.76, longitude: 113.65)], position: p,
            overview: false, positionFraction: 0.66, bottomOverlayInset: 230)
        for angle in [0.0,90,180,270,359,1,45,0] {
            value.heading = angle; view.update(value)
            let coordinate = ChinaCoordinateTransform.mapCoordinate(for: p.geo).clCoordinate
            let screen = view.map.convert(coordinate, toPointTo: view)
            XCTAssertEqual(screen.x, 195, accuracy: 2)
            XCTAssertEqual(screen.y, 844 * 0.66, accuracy: 2)
            XCTAssertEqual(view.map.camera.centerCoordinate.latitude, coordinate.latitude, accuracy: 0.000001)
            XCTAssertEqual(view.map.camera.centerCoordinate.longitude, coordinate.longitude, accuracy: 0.000001)
            XCTAssertEqual(RoadbookCourse.signedAngle(view.map.camera.heading-angle), 0, accuracy: 0.1)
        }
    }
}
