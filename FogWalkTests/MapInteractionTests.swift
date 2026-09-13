import XCTest
import SwiftUI
import MapKit
@testable import FogWalk

@MainActor
final class MapInteractionTests: XCTestCase {
    func testSelectionChangesRouteWithoutRebuildingFogOrMovingCamera() async throws {
        let state = MapHarnessState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: MapHarness(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let map = try XCTUnwrap(findMap(host.view))
        let fog = try XCTUnwrap(map.overlays.first(where: { $0 is ExplorationOverlay }))
        let center = map.centerCoordinate
        state.selected = state.secondID
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(map.overlays.contains(where: { ($0 as AnyObject) === (fog as AnyObject) }))
        XCTAssertEqual(map.centerCoordinate.latitude, center.latitude, accuracy: 0.0001)
        XCTAssertEqual(map.centerCoordinate.longitude, center.longitude, accuracy: 0.0001)
        let polyline = try XCTUnwrap(map.overlays.first(where: { $0 is MKPolyline }) as? MKPolyline)
        var end = CLLocationCoordinate2D()
        polyline.getCoordinates(&end, range: NSRange(location: polyline.pointCount - 1, length: 1))
        XCTAssertEqual(end.longitude, state.second.longitude, accuracy: 0.0001)
        let firstMarker = try XCTUnwrap(map.annotations.first(where: { abs($0.coordinate.longitude - state.first.longitude) < 0.00001 }))
        map.delegate?.mapView?(map, didSelect: firstMarker)
        XCTAssertEqual(state.selected, state.firstID)
    }

    func testLocationButtonRestoresFixedLocalViewportOnRepeatedRequests() async throws {
        let state = MapHarnessState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: MapHarness(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        let map = try XCTUnwrap(findMap(host.view))
        for _ in 0..<2 {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 115),
                latitudinalMeters: 1_000_000, longitudinalMeters: 1_000_000), animated: false)
            let rotated = map.camera.copy() as! MKMapCamera
            rotated.heading = 125
            map.setCamera(rotated, animated: false)
            state.recenter += 1
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(map.centerCoordinate.latitude, state.start.latitude, accuracy: 0.0001)
            XCTAssertEqual(map.centerCoordinate.longitude, state.start.longitude, accuracy: 0.0001)
            XCTAssertLessThan(map.region.span.latitudeDelta, 0.1)
            XCTAssertEqual(map.camera.heading, 0, accuracy: 0.1)
            XCTAssertEqual(map.camera.pitch, 0, accuracy: 0.1)
        }
    }

    func testHomeHeadingContinuesAfterZoomAndPanAndRecenterPreservesScale() async throws {
        let state = MapHarnessState()
        state.orientation = .phoneHeading
        state.heading = 90
        state.live = state.start
        state.follows = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: MapHarness(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let map = try XCTUnwrap(findMap(host.view))
        let fog = try XCTUnwrap(map.overlays.first(where: { $0 is ExplorationOverlay }))
        XCTAssertFalse(map.showsUserLocation)
        XCTAssertFalse(map.isRotateEnabled)
        XCTAssertEqual(map.camera.heading, 90, accuracy: 0.1)
        let annotation = try XCTUnwrap(map.annotations.first(where: { $0 is HomeLocationAnnotation }))
        let arrow = try await waitForArrow(on: map, annotation: annotation)
        XCTAssertNotNil(arrow.directionImageView.image)
        XCTAssertEqual(atan2(arrow.directionImageView.transform.b, arrow.directionImageView.transform.a), 0, accuracy: 0.01)

        // Keep the heading assertion's marker on screen throughout this walk;
        // offscreen annotation views are legitimately culled/reused by MapKit.
        let walkedCoordinate = GeoCoordinate(latitude: 31.2302, longitude: 121.4702)
        state.live = walkedCoordinate
        state.heading = 180
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(map.camera.heading, 180, accuracy: 0.1)
        XCTAssertEqual(map.centerCoordinate.latitude, walkedCoordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(annotation.coordinate.longitude, walkedCoordinate.longitude, accuracy: 0.0001)
        XCTAssertTrue(map.overlays.contains(where: { ($0 as AnyObject) === (fog as AnyObject) }))

        // Exercise the same immediate coordinator gate set by a map gesture,
        // before the asynchronous SwiftUI pause notification has been delivered.
        let coordinator = try XCTUnwrap(map.delegate as? FogMapView.Coordinator)
        coordinator.hasUserMovedMap = true
        let browsingCenter = GeoCoordinate(latitude: 31.2305, longitude: 121.4705)
        let zoomed = map.camera.copy() as! MKMapCamera
        zoomed.centerCoordinate = browsingCenter.clCoordinate
        zoomed.centerCoordinateDistance *= 0.7
        map.setCamera(zoomed, animated: false)
        let zoomDistance = map.camera.centerCoordinateDistance
        state.follows = false
        state.heading = 270
        state.live = state.start
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(map.centerCoordinate.latitude, browsingCenter.latitude, accuracy: 0.0001)
        XCTAssertEqual(map.camera.heading, 270, accuracy: 0.1)
        XCTAssertEqual(map.camera.centerCoordinateDistance, zoomDistance, accuracy: 1)
        let visibleArrow = try await waitForArrow(on: map, annotation: annotation)
        XCTAssertEqual(atan2(visibleArrow.directionImageView.transform.b, visibleArrow.directionImageView.transform.a), 0, accuracy: 0.01)

        state.orientation = .northUp
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(map.camera.heading, 0, accuracy: 0.1)
        XCTAssertEqual(map.centerCoordinate.latitude, browsingCenter.latitude, accuracy: 0.0001)
        XCTAssertEqual(map.camera.centerCoordinateDistance, zoomDistance, accuracy: 1)
        state.heading = 45
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(map.camera.heading, 0, accuracy: 0.1)
        state.recenter += 1
        state.follows = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(map.centerCoordinate.latitude, state.start.latitude, accuracy: 0.0001)
        XCTAssertEqual(map.camera.heading, 0, accuracy: 0.1)
        XCTAssertEqual(map.camera.centerCoordinateDistance, zoomDistance, accuracy: 1)
        XCTAssertFalse(coordinator.hasUserMovedMap)
        state.live = nil
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(map.annotations.contains(where: { $0 is HomeLocationAnnotation }))
    }

    private func findMap(_ view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        return view.subviews.compactMap { findMap($0) }.first
    }

    private func waitForArrow(on map: MKMapView, annotation: MKAnnotation) async throws -> HomeLocationAnnotationView {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            map.layoutIfNeeded()
            if let view = map.view(for: annotation) as? HomeLocationAnnotationView { return view }
            try await Task.sleep(for: .milliseconds(50))
        }
        let point = map.convert(annotation.coordinate, toPointTo: map)
        let screenshot = UIGraphicsImageRenderer(bounds: map.bounds).image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Missing location arrow"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(map.view(for: annotation) as? HomeLocationAnnotationView,
            "Arrow missing after layout: point=\(point), bounds=\(map.bounds), coordinate=\(annotation.coordinate), center=\(map.centerCoordinate), heading=\(map.camera.heading)")
    }

    func testUnitTestsUseIsolatedHost() {
        XCTAssertTrue(AppRuntime.isUnitTestHost)
    }

    func testMapControlSymbolsAndArrowSurviveAnnotationLayout() {
        for orientation in MapOrientation.allCases { XCTAssertNotNil(UIImage(systemName: orientation.icon)) }
        let view = HomeLocationAnnotationView(annotation: nil, reuseIdentifier: "heading-test")
        view.update(heading: 270, cameraHeading: 180)
        view.transform = .identity
        view.layoutIfNeeded()
        XCTAssertEqual(atan2(view.directionImageView.transform.b, view.directionImageView.transform.a), .pi / 2, accuracy: 0.01)
        view.update(heading: nil, cameraHeading: 180)
        XCTAssertNotNil(view.directionImageView.image)
        XCTAssertEqual(view.directionImageView.transform, .identity)
    }
}

@MainActor
private final class MapHarnessState: ObservableObject {
    let firstID = UUID()
    let secondID = UUID()
    let start = GeoCoordinate(latitude: 31.23, longitude: 121.47)
    let first = GeoCoordinate(latitude: 31.24, longitude: 121.48)
    let second = GeoCoordinate(latitude: 31.25, longitude: 121.49)
    @Published var selected: UUID?
    @Published var recenter = 0
    @Published var orientation: MapOrientation?
    @Published var heading: Double?
    @Published var live: GeoCoordinate?
    @Published var follows = false
    init() { selected = firstID }
}

private struct MapHarness: View {
    @ObservedObject var state: MapHarnessState
    var body: some View {
        FogMapView(presentation: .empty, isFogVisible: true, isTrackVisible: false,
            currentCoordinate: state.start, liveCurrentCoordinate: state.live, centersOnCurrentCoordinate: true,
            recenterCoordinate: state.start, recenterRequestID: state.recenter,
            highlightedRoute: [state.start, state.selected == state.firstID ? state.first : state.second],
            destinationCoordinate: state.selected == state.firstID ? state.first : state.second,
            destinationMarkers: [ExploreMapDestination(id: state.firstID, coordinate: state.first, rank: 1),
                                 ExploreMapDestination(id: state.secondID, coordinate: state.second, rank: 2)],
            selectedDestinationID: state.selected, onDestinationSelection: { state.selected = $0 },
            orientation: state.orientation, deviceHeading: state.heading, followsCurrentLocation: state.follows,
            onUserMovedMap: { state.follows = false })
    }
}
