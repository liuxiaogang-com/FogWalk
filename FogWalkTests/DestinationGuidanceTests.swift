import XCTest
@testable import FogWalk

final class DestinationGuidanceTests: XCTestCase {
    func testBearingAndMapHeadingProduceScreenRelativeDirection() throws {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        let north = try XCTUnwrap(DestinationGuidance(
            origin: origin,
            destination: GeoCoordinate(latitude: 1, longitude: 0)
        ))
        XCTAssertEqual(north.bearingDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(north.screenBearing(mapHeading: 90), 270, accuracy: 0.001)

        let east = try XCTUnwrap(DestinationGuidance(
            origin: origin,
            destination: GeoCoordinate(latitude: 0, longitude: 1)
        ))
        XCTAssertEqual(east.bearingDegrees, 90, accuracy: 0.001)
        XCTAssertEqual(east.screenBearing(mapHeading: 45), 45, accuracy: 0.001)
    }

    func testDistanceLabelsStayReadableAcrossWalkingRanges() {
        XCTAssertEqual(DestinationGuidance.distanceText(meters: 42.4), "42 米")
        XCTAssertEqual(DestinationGuidance.distanceText(meters: 846), "850 米")
        XCTAssertEqual(DestinationGuidance.distanceText(meters: 1_850), "1.9 公里")
        XCTAssertEqual(DestinationGuidance.distanceText(meters: 12_400), "12 公里")
    }
}
