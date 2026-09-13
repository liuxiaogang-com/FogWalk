import XCTest
import CoreLocation
@testable import FogWalk

@MainActor
final class HomeMapLocationTests: XCTestCase {
    func testRecenterWaitsForFixAfterTapAndConvertsMapCoordinateOnce() throws {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.requestRecenter()
        let requested = try XCTUnwrap(sut.requestedAt)
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested.addingTimeInterval(-10))])
        XCTAssertTrue(sut.isLocating)
        XCTAssertEqual(sut.recenterRequestID, 0)
        XCTAssertNil(sut.recenterCoordinate)
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested)])
        XCTAssertFalse(sut.isLocating)
        XCTAssertTrue(sut.isFollowing)
        XCTAssertEqual(sut.recenterRequestID, 1)
        XCTAssertEqual(sut.recenterCoordinate, ChinaCoordinateTransform.mapCoordinate(for:
            GeoCoordinate(latitude: 31.23, longitude: 121.47)))
        sut.requestRecenter()
        XCTAssertNil(sut.recenterCoordinate)
        XCTAssertFalse(sut.isFollowing)
        sut.locationManager(manager, didUpdateLocations: [fix(at: Date())])
        XCTAssertEqual(sut.recenterRequestID, 2)
    }

    func testInvalidOldAndOutOfOrderFixesCannotCompleteOrMoveRecenter() throws {
        let manager = MapSensorStub()
        let sut = HomeMapLocation(manager: manager)
        sut.setActive(true)
        defer { sut.setActive(false) }
        sut.requestRecenter()
        let requested = try XCTUnwrap(sut.requestedAt)
        sut.locationManager(manager, didUpdateLocations: [fix(at: requested, accuracy: -1),
            fix(at: requested, accuracy: 500), fix(at: requested.addingTimeInterval(-60)),
            fix(at: requested.addingTimeInterval(60))])
        XCTAssertNil(sut.coordinate)
        XCTAssertTrue(sut.isLocating)
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
        XCTAssertFalse(sut.isLocating)
        sut.locationManager(manager, didUpdateLocations: [fix(at: Date())])
        XCTAssertNil(sut.coordinate)
        XCTAssertEqual(sut.recenterRequestID, 0)
    }

    func testDeniedPermissionAndCancelledGestureDoNotLeavePendingRecenter() {
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
        XCTAssertFalse(sut.isLocating)
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
        sut.selectOrientation(.phoneHeading)
        let restored = HomeMapLocation(manager: MapSensorStub(), preferences: preferences)
        XCTAssertEqual(restored.orientation, .phoneHeading)
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
    var locationStops = 0
    var headingStops = 0
    override var authorizationStatus: CLAuthorizationStatus { permission }
    override func startUpdatingLocation() {}
    override func startUpdatingHeading() {}
    override func stopUpdatingLocation() { locationStops += 1 }
    override func stopUpdatingHeading() { headingStops += 1 }
    override func requestWhenInUseAuthorization() {}
}
