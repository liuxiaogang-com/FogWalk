import XCTest
@testable import FogWalk

final class ExternalNavigationTests: XCTestCase {
    private let destination = GeoCoordinate(latitude: 31.228457, longitude: 121.477223)

    func testAMapPreservesMapCoordinateAndEncodesChineseNames() throws {
        let name = "瑞幸咖啡（A&B 店） + #? / 茶饮"
        let url = try ExternalNavigation.amapURL(coordinate: destination, name: name, travelMode: .walking)
        let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parsed.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parsed.scheme, "iosamap")
        XCTAssertEqual(parsed.host, "path")
        XCTAssertEqual(query["dname"], name)
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(query["sourceApplication"], "迷雾足迹")
        XCTAssertEqual(Double(query["dlat"] ?? ""), destination.latitude)
        XCTAssertEqual(Double(query["dlon"] ?? ""), destination.longitude)
        XCTAssertEqual(query["dev"], "0", "Already converted map coordinates must never be offset twice")
        XCTAssertNil(query["slat"], "Let AMap locate the actual current origin")
        XCTAssertNil(query["slon"])
        XCTAssertNil(query["did"], "Apple POI IDs must not be sent as AMap POI IDs")
    }

    func testAMapTravelModes() throws {
        for (mode, expected) in [(ExploreTravelMode.walking, "2"), (.cycling, "3"), (.automobile, "0")] {
            let url = try ExternalNavigation.amapURL(coordinate: destination, name: "目的地", travelMode: mode)
            let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parsed.queryItems?.first { $0.name == "t" }?.value, expected)
        }
    }

    func testInvalidCoordinateDoesNotLaunchNavigation() {
        for coordinate in [GeoCoordinate(latitude: .nan, longitude: 121),
                           GeoCoordinate(latitude: 91, longitude: 121),
                           GeoCoordinate(latitude: 31, longitude: .infinity)] {
            XCTAssertThrowsError(try ExternalNavigation.amapURL(coordinate: coordinate, name: "", travelMode: .walking))
        }
    }

    func testOnlyRequestedProvidersAreOffered() {
        XCTAssertEqual(NavigationApp.allCases, [.amap, .apple])
    }
}
