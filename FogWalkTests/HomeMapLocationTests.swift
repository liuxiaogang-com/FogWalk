import XCTest
import CoreLocation
@testable import FogWalk

@MainActor
final class HomeMapLocationTests: XCTestCase {
    func testRecenterImmediatelyUsesDisplayedFixWithoutRestartingGPS() {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.locationManager(manager, didUpdateLocations: [fix(at: Date().addingTimeInterval(-10))])
        let displayed = sut.coordinate
        let starts = manager.locationStarts
        sut.pauseFollowing()
        for request in 1...2 {
            sut.requestRecenter()
            XCTAssertEqual(sut.recenterRequestID, request)
            XCTAssertEqual(sut.recenterCoordinate, displayed)
            XCTAssertTrue(sut.isFollowing)
        }
        XCTAssertEqual(manager.locationStarts, starts)
        XCTAssertEqual(displayed, ChinaCoordinateTransform.mapCoordinate(for:
            GeoCoordinate(latitude: 31.23, longitude: 121.47)))
    }

    func testInvalidOldAndOutOfOrderFixesCannotCompleteOrMoveRecenter() throws {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.requestRecenter()
        let requested = Date()
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested, accuracy: -1),
            fix(at: requested, accuracy: 500), fix(at: requested.addingTimeInterval(-60)),
            fix(at: requested.addingTimeInterval(60))])
        XCTAssertNil(sut.coordinate)
        XCTAssertEqual(sut.recenterRequestID, 0)
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested)])
        let coordinate = sut.coordinate
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested.addingTimeInterval(-1), latitude: 32)])
        XCTAssertEqual(sut.coordinate, coordinate)
        sut.expireLocation(now: requested.addingTimeInterval(31))
        XCTAssertNil(sut.coordinate)
    }

    func testBackgroundStopsOnlyMapSensorsAndIgnoresLateFix() {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        sut.requestRecenter()
        sut.setActive(false)
        XCTAssertEqual(manager.locationStops, 1)
        XCTAssertEqual(manager.headingStops, 1)
        sut.locationManager(manager, didUpdateLocations: [fix(at: Date())])
        XCTAssertNil(sut.coordinate)
        XCTAssertEqual(sut.recenterRequestID, 0)
    }

    func testMissingPositionAndDeniedPermissionDoNotQueueDelayedRecenter() {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.requestRecenter()
        sut.pauseFollowing()
        sut.locationManager(manager, didUpdateLocations: [fix(at: Date())])
        XCTAssertFalse(sut.isFollowing)
        XCTAssertEqual(sut.recenterRequestID, 0)
        manager.permission = .denied
        sut.locationManagerDidChangeAuthorization(manager)
        sut.requestRecenter()
        XCTAssertNil(sut.coordinate)
        XCTAssertNotNil(sut.message)
    }

    func testOrientationPersistsAndInvalidHeadingDoesNotBecomeNorth() throws {
        let suite = "HomeMapLocationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let sut = HomeMapLocation(manager: MapSensorStub(), preferences: preferences)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.pauseFollowing()
        let starts = (sut.isFollowing, sut.recenterRequestID)
        sut.toggleOrientation()
        XCTAssertEqual(sut.orientation, .phoneHeading)
        XCTAssertEqual(sut.isFollowing, starts.0)
        XCTAssertEqual(sut.recenterRequestID, starts.1)
        let restored = HomeMapLocation(manager: MapSensorStub(), preferences: preferences)
        XCTAssertEqual(restored.orientation, .phoneHeading)
        sut.toggleOrientation()
        XCTAssertEqual(sut.orientation, .northUp)
        XCTAssertEqual(sut.recenterRequestID, 0)
        XCTAssertEqual(HomeMapLocation.validHeading(trueHeading: 0, magneticHeading: 12, accuracy: 5), 0)
        XCTAssertEqual(HomeMapLocation.validHeading(trueHeading: -1, magneticHeading: 359, accuracy: 5), 359)
        XCTAssertNil(HomeMapLocation.validHeading(trueHeading: 12, magneticHeading: 10, accuracy: -1))
        XCTAssertNil(HomeMapLocation.validHeading(trueHeading: -1, magneticHeading: -1, accuracy: 5))
        XCTAssertNil(HomeMapLocation.validHeading(trueHeading: .nan, magneticHeading: .nan, accuracy: 5))
    }

    private func fix(at date: Date, accuracy: Double = 5, latitude: Double = 31.23) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 121.47),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: date)
    }
}

private final class MapSensorStub: CLLocationManager {
    var permission: CLAuthorizationStatus = .authorizedWhenInUse
    var locationStarts = 0
    var locationStops = 0
    var headingStops = 0
    override var authorizationStatus: CLAuthorizationStatus { permission }
    override func startUpdatingLocation() { locationStarts += 1 }
    override func startUpdatingHeading() {}
    override func stopUpdatingLocation() { locationStops += 1 }
    override func stopUpdatingHeading() { headingStops += 1 }
    override func requestWhenInUseAuthorization() {}
}
