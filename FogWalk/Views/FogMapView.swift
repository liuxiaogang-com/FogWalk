import SwiftUI
import MapKit

struct ExploreMapDestination: Identifiable, Equatable {
    let id: UUID
    let coordinate: GeoCoordinate
    let rank: Int
}

struct FogMapView: UIViewRepresentable {
    let presentation: TrackPresentation
    let isFogVisible: Bool
    let isTrackVisible: Bool
    let currentCoordinate: GeoCoordinate?
    var liveCurrentCoordinate: GeoCoordinate?
    var centersOnCurrentCoordinate = false
    var initialSpanMeters: CLLocationDistance = 4_000
    var showsBasePOIs = true
    var recenterCoordinate: GeoCoordinate?
    var recenterRequestID = 0
    var recenterSpanMeters: CLLocationDistance = 3_000
    var trackPresentation: TrackPresentation?
    var overviewRequestID = 0
    var highlightedRoute: [GeoCoordinate] = []
    var destinationCoordinate: GeoCoordinate?
    var destinationMarkers: [ExploreMapDestination] = []
    var selectedDestinationID: UUID?
    var onDestinationSelection: ((UUID) -> Void)?
    var isLongPressSelectionEnabled = false
    var onLongPressSelection: ((GeoCoordinate) -> Void)?
    // Only the home map owns these controls; destination maps keep their camera behavior.
    var orientation: MapOrientation?
    var deviceHeading: Double?
    var followsCurrentLocation = false
    var onUserMovedMap: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> FogMapCanvas {
        let canvas = FogMapCanvas(frame: .zero)
        let mapView = canvas.mapView
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = true
        mapView.showsUserLocation = orientation == nil
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { mapView.showsUserLocation = false }
        #endif
        mapView.isPitchEnabled = false
        // A dark base map keeps the revealed corridor legible without the
        // harsh white "light tube" effect produced by cutting a light map out
        // of a nearly black overlay.
        mapView.overrideUserInterfaceStyle = .dark
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = showsBasePOIs ? .includingAll : .excludingAll
        mapView.preferredConfiguration = configuration
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 12
        mapView.addGestureRecognizer(longPress)
        setInitialViewport(on: canvas,
            center: (liveCurrentCoordinate ?? currentCoordinate ?? presentation.latestCoordinate)?.clCoordinate
                ?? CLLocationCoordinate2D(latitude: 35, longitude: 105), animated: false)
        return canvas
    }

    private func setInitialViewport(on canvas: FogMapCanvas, center: CLLocationCoordinate2D, animated: Bool) {
        let mapView = canvas.mapView
        if let orientation {
            // The representable initially has zero bounds. Use an explicit
            // distance before copying its camera for heading/position updates.
            canvas.setHomeCamera(MKMapCamera(lookingAtCenter: center, fromDistance: initialSpanMeters,
                pitch: 0, heading: orientation == .phoneHeading ? (deviceHeading ?? 0) : 0), animated: animated)
        } else {
            mapView.setRegion(MKCoordinateRegion(center: center,
                latitudinalMeters: initialSpanMeters, longitudinalMeters: initialSpanMeters), animated: animated)
        }
    }

    func updateUIView(_ canvas: FogMapCanvas, context: Context) {
        let mapView = canvas.mapView
        context.coordinator.isLongPressSelectionEnabled = isLongPressSelectionEnabled
        context.coordinator.onLongPressSelection = onLongPressSelection
        context.coordinator.onDestinationSelection = onDestinationSelection
        context.coordinator.onUserMovedMap = onUserMovedMap
        context.coordinator.deviceHeading = deviceHeading
        mapView.isRotateEnabled = orientation == nil

        if context.coordinator.lastRecenterRequestID != recenterRequestID,
           let recenterCoordinate {
            context.coordinator.lastRecenterRequestID = recenterRequestID
            context.coordinator.hasPositionedMap = true
            context.coordinator.hasAppliedLiveCenter = true
            context.coordinator.hasUserMovedMap = false
            let distance = CLLocation(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
                .distance(from: recenterCoordinate.location)
            let camera = orientation == nil
                ? MKMapCamera(lookingAtCenter: recenterCoordinate.clCoordinate, fromDistance: recenterSpanMeters, pitch: 0, heading: 0)
                : canvas.homeCameraSnapshot
            camera.centerCoordinate = recenterCoordinate.clCoordinate
            camera.heading = orientation == .phoneHeading ? (deviceHeading ?? camera.heading) : 0
            camera.pitch = 0
            if orientation != nil {
                canvas.setHomeCamera(camera, animated: false)
            } else {
                mapView.setCamera(camera, animated: distance < 10_000 && mapView.region.span.latitudeDelta < 0.2)
            }
        }

        if centersOnCurrentCoordinate,
           let liveCurrentCoordinate,
           !context.coordinator.hasAppliedLiveCenter,
           !context.coordinator.hasUserMovedMap {
            context.coordinator.hasAppliedLiveCenter = true
            context.coordinator.hasPositionedMap = true
            setInitialViewport(on: canvas, center: liveCurrentCoordinate.clCoordinate,
                animated: orientation == nil && context.coordinator.overlayState != nil)
        }
        let state = OverlayState(
            revision: presentation.revision,
            trackRevision: trackPresentation?.revision ?? presentation.revision,
            fog: isFogVisible,
            track: isTrackVisible,
            route: highlightedRoute,
            destination: destinationCoordinate,
            destinationMarkers: destinationMarkers,
            selectedDestinationID: selectedDestinationID
        )
        let previousState = context.coordinator.overlayState
        if context.coordinator.overlayState != state {
            let baseChanged = previousState?.revision != state.revision
                || previousState?.trackRevision != state.trackRevision
                || previousState?.fog != state.fog || previousState?.track != state.track
            let removed = context.coordinator.overlays.filter { baseChanged || $0 is MKPolyline }
            mapView.removeOverlays(removed)
            if !context.coordinator.annotations.isEmpty {
                mapView.removeAnnotations(context.coordinator.annotations)
            }
            var overlays: [MKOverlay] = baseChanged ? [] : context.coordinator.overlays.filter { $0 is ExplorationOverlay }
            if baseChanged && isFogVisible {
                overlays.append(
                    ExplorationOverlay(presentation: presentation, showFog: true, showTrack: false)
                )
            }
            if baseChanged && isTrackVisible {
                overlays.append(
                    ExplorationOverlay(presentation: trackPresentation ?? presentation, showFog: false, showTrack: true)
                )
            }
            if highlightedRoute.count >= 2 {
                var coordinates = highlightedRoute.map(\.clCoordinate)
                overlays.append(MKPolyline(coordinates: &coordinates, count: coordinates.count))
            }
            context.coordinator.overlays = overlays
            context.coordinator.overlayState = state
            if baseChanged, let fogOverlay = overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showFog }) {
                mapView.addOverlay(fogOverlay, level: .aboveLabels)
            }
            if baseChanged, let trackOverlay = overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showTrack }) {
                if let fogOverlay = overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showFog }) {
                    mapView.insertOverlay(trackOverlay, above: fogOverlay)
                } else {
                    mapView.addOverlay(trackOverlay, level: .aboveLabels)
                }
            }
            if let routeOverlay = overlays.first(where: { $0 is MKPolyline }) {
                mapView.addOverlay(routeOverlay, level: .aboveLabels)
            }
            if !destinationMarkers.isEmpty {
                let annotations = destinationMarkers.map { destination in
                    ExploreDestinationAnnotation(
                        id: destination.id,
                        coordinate: destination.coordinate.clCoordinate,
                        rank: destination.rank,
                        isSelectedDestination: destination.id == selectedDestinationID
                    )
                }
                context.coordinator.annotations = annotations
                mapView.addAnnotations(annotations)
            } else if let destinationCoordinate {
                let annotation = ExploreDestinationAnnotation(coordinate: destinationCoordinate.clCoordinate)
                context.coordinator.annotations = [annotation]
                mapView.addAnnotation(annotation)
            } else {
                context.coordinator.annotations = []
            }

        }

        let newResultSet = !destinationMarkers.isEmpty
            && previousState?.destinationMarkers.map(\.id) != destinationMarkers.map(\.id)
        let explicitOverview = context.coordinator.lastOverviewRequestID != overviewRequestID
        if explicitOverview || (newResultSet && !context.coordinator.hasUserMovedMap) {
            context.coordinator.lastOverviewRequestID = overviewRequestID
            let coordinates = destinationMarkers.map(\.coordinate) + highlightedRoute
                + [destinationCoordinate, currentCoordinate].compactMap { $0 }
            var rect = MKMapRect.null
            for coordinate in coordinates {
                let point = MKMapPoint(coordinate.clCoordinate)
                let size = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * 100
                rect = rect.union(MKMapRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2))
            }
            if destinationMarkers.isEmpty, highlightedRoute.isEmpty, destinationCoordinate == nil,
               let track = context.coordinator.overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showTrack }),
               !track.contentMapRect.isNull, !track.contentMapRect.isEmpty {
                rect = track.contentMapRect
            }
            if !rect.isNull {
                context.coordinator.hasPositionedMap = true
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 230, left: 40, bottom: 330, right: 40), animated: true)
            }
        }

        if !context.coordinator.hasPositionedMap,
           let coordinate = currentCoordinate ?? presentation.latestCoordinate {
            context.coordinator.hasPositionedMap = true
            if centersOnCurrentCoordinate {
                setInitialViewport(on: canvas, center: coordinate.clCoordinate, animated: false)
            } else if let overlay = context.coordinator.overlays.compactMap({ $0 as? ExplorationOverlay }).first,
                      !overlay.contentMapRect.isNull,
                      !overlay.contentMapRect.isEmpty {
                mapView.setVisibleMapRect(
                    overlay.contentMapRect,
                    edgePadding: UIEdgeInsets(top: 145, left: 28, bottom: 245, right: 28),
                    animated: false
                )
            } else {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: coordinate.clCoordinate,
                        latitudinalMeters: 4_000,
                        longitudinalMeters: 4_000
                    ),
                    animated: false
                )
            }
        }
        if let orientation {
            context.coordinator.updateHomeLocation(on: mapView, coordinate: liveCurrentCoordinate)
            context.coordinator.updateHomeCamera(on: canvas, orientation: orientation,
                                                 coordinate: liveCurrentCoordinate, follows: followsCurrentLocation)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [MKOverlay] = []
        var annotations: [MKAnnotation] = []
        fileprivate var overlayState: OverlayState?
        var hasPositionedMap = false
        var hasAppliedLiveCenter = false
        var lastRecenterRequestID = 0
        var lastOverviewRequestID = 0
        var hasUserMovedMap = false
        var isLongPressSelectionEnabled = false
        var onLongPressSelection: ((GeoCoordinate) -> Void)?
        var onDestinationSelection: ((UUID) -> Void)?
        var onUserMovedMap: (() -> Void)?
        var deviceHeading: Double?
        var liveAnnotation: HomeLocationAnnotation?
        private var lastOrientation: MapOrientation?
        private var lastFollowCoordinate: GeoCoordinate?

        func updateHomeLocation(on mapView: MKMapView, coordinate: GeoCoordinate?) {
            if let coordinate {
                if let liveAnnotation {
                    if liveAnnotation.coordinate.latitude != coordinate.latitude || liveAnnotation.coordinate.longitude != coordinate.longitude {
                        liveAnnotation.coordinate = coordinate.clCoordinate
                    }
                } else {
                    let annotation = HomeLocationAnnotation(coordinate: coordinate.clCoordinate)
                    liveAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            } else if let liveAnnotation {
                mapView.removeAnnotation(liveAnnotation)
                self.liveAnnotation = nil
            }
            updateHeadingArrow(on: mapView)
        }

        func updateHomeCamera(on canvas: FogMapCanvas, orientation: MapOrientation,
                              coordinate: GeoCoordinate?, follows: Bool) {
            let mapView = canvas.mapView
            let orientationChanged = lastOrientation != orientation
            lastOrientation = orientation
            let currentCamera = canvas.homeCameraSnapshot
            let targetHeading = orientation == .northUp ? 0 : (deviceHeading ?? currentCamera.heading)
            let canFollow = follows && !hasUserMovedMap && coordinate != nil
            let headingChanged = abs(currentCamera.heading - targetHeading) > 0.1
            if orientationChanged || headingChanged || (canFollow && lastFollowCoordinate != coordinate) {
                let camera = currentCamera
                if canFollow, let coordinate { camera.centerCoordinate = coordinate.clCoordinate }
                // Position following and orientation are independent. Copying the
                // current camera preserves the user's zoom and browsing center.
                camera.heading = targetHeading
                camera.pitch = 0
                canvas.setHomeCamera(camera, animated: false)
                lastFollowCoordinate = canFollow ? coordinate : nil
            }
            if !canFollow { lastFollowCoordinate = nil }
            updateHeadingArrow(on: mapView)
        }

        func updateHeadingArrow(on mapView: MKMapView) {
            guard let liveAnnotation, let view = mapView.view(for: liveAnnotation) as? HomeLocationAnnotationView else { return }
            view.update(heading: deviceHeading, cameraHeading: mapView.camera.heading)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateHeadingArrow(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            func isInteracting(_ view: UIView) -> Bool {
                if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { return true }
                return view.subviews.contains(where: isInteracting)
            }
            if isInteracting(mapView) {
                hasUserMovedMap = true
                // Delegate callbacks can run during a representable update.
                let callback = onUserMovedMap
                DispatchQueue.main.async { callback?() }
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  isLongPressSelectionEnabled,
                  let mapView = gesture.view as? MKMapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            onLongPressSelection?(
                GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let explorationOverlay = overlay as? ExplorationOverlay {
                return ExplorationOverlayRenderer(overlay: explorationOverlay)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemCyan
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is HomeLocationAnnotation {
                let identifier = "HomeCurrentLocation"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? HomeLocationAnnotationView
                    ?? HomeLocationAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.displayPriority = .required
                view.zPriority = .max
                view.isEnabled = false
                view.isAccessibilityElement = true
                view.update(heading: deviceHeading, cameraHeading: mapView.camera.heading)
                return view
            }
            guard let destination = annotation as? ExploreDestinationAnnotation else { return nil }
            let identifier = "ExploreDestination"
            let marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            marker.annotation = annotation
            marker.markerTintColor = destination.isSelectedDestination ? .systemOrange : .systemTeal
            if let rank = destination.rank {
                marker.glyphText = "\(rank)"
                marker.glyphImage = nil
            } else {
                marker.glyphText = nil
                marker.glyphImage = UIImage(systemName: "flag.fill")
            }
            marker.displayPriority = destination.isSelectedDestination ? .required : .defaultHigh
            return marker
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            updateHeadingArrow(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let destination = annotation as? ExploreDestinationAnnotation,
                  let id = destination.id else { return }
            onDestinationSelection?(id)
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}

final class FogMapCanvas: UIView {
    let mapView = MKMapView(frame: .zero)
    private var hasCompletedLayout = false
    private var pendingHomeCamera: MKMapCamera?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(mapView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(mapView)
    }

    var homeCameraSnapshot: MKMapCamera {
        (pendingHomeCamera ?? mapView.camera).copy() as! MKMapCamera
    }

    func setHomeCamera(_ camera: MKMapCamera, animated: Bool) {
        guard hasCompletedLayout, !bounds.isEmpty else {
            pendingHomeCamera = camera.copy() as? MKMapCamera
            return
        }
        pendingHomeCamera = nil
        mapView.setCamera(camera, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        mapView.frame = bounds
        mapView.layoutIfNeeded()
        hasCompletedLayout = true
        // MapKit clamps cameras applied at zero size to its minimum distance.
        // Apply the latest requested home camera once actual geometry exists.
        if let pendingHomeCamera {
            self.pendingHomeCamera = nil
            mapView.setCamera(pendingHomeCamera, animated: false)
        }
    }
}

final class HomeLocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

final class HomeLocationAnnotationView: MKAnnotationView {
    let directionImageView = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        directionImageView.frame = CGRect(x: 5, y: 5, width: 34, height: 34)
        directionImageView.contentMode = .scaleAspectFit
        directionImageView.backgroundColor = .white
        directionImageView.layer.cornerRadius = 17
        addSubview(directionImageView)
    }

    func update(heading: Double?, cameraHeading: Double) {
        let symbol = heading == nil ? "smallcircle.filled.circle.fill" : "location.north.circle.fill"
        directionImageView.image = UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold))?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        // MapKit owns the annotation view's transform during camera/layout updates.
        // Rotate its content instead, so panning and view reuse cannot reset the arrow.
        directionImageView.transform = CGAffineTransform(rotationAngle: CGFloat((heading ?? cameraHeading) - cameraHeading) * .pi / 180)
        accessibilityLabel = heading == nil ? "当前位置，方向暂不可用" : "当前位置与手机朝向"
    }
}

fileprivate struct OverlayState: Equatable {
    let revision: Int
    let trackRevision: Int
    let fog: Bool
    let track: Bool
    let route: [GeoCoordinate]
    let destination: GeoCoordinate?
    let destinationMarkers: [ExploreMapDestination]
    let selectedDestinationID: UUID?
}

private final class ExploreDestinationAnnotation: NSObject, MKAnnotation {
    let id: UUID?
    let coordinate: CLLocationCoordinate2D
    let rank: Int?
    let isSelectedDestination: Bool

    init(coordinate: CLLocationCoordinate2D) {
        id = nil
        self.coordinate = coordinate
        rank = nil
        isSelectedDestination = true
        super.init()
    }

    init(id: UUID, coordinate: CLLocationCoordinate2D, rank: Int, isSelectedDestination: Bool) {
        self.id = id
        self.coordinate = coordinate
        self.rank = rank
        self.isSelectedDestination = isSelectedDestination
        super.init()
    }
}

final class ExplorationOverlay: NSObject, MKOverlay {
    struct Path {
        let points: [MKMapPoint]
        let bounds: MKMapRect
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let paths: [Path]
    let isolatedPoints: [MKMapPoint]
    let showFog: Bool
    let showTrack: Bool
    let referenceLatitude: Double
    let contentMapRect: MKMapRect

    init(presentation: TrackPresentation, showFog: Bool, showTrack: Bool) {
        self.showFog = showFog
        self.showTrack = showTrack
        referenceLatitude = presentation.latestCoordinate?.latitude ?? 35
        let mappedPaths = presentation.segments.map { segment in
            let points = segment.coordinates.map { MKMapPoint($0.clCoordinate) }
            return Path(points: points, bounds: Self.bounds(for: points))
        }
        let mappedIsolatedPoints = presentation.isolatedPoints.map { MKMapPoint($0.clCoordinate) }
        paths = mappedPaths
        isolatedPoints = mappedIsolatedPoints
        var contentBounds = mappedPaths.reduce(MKMapRect.null) { partial, path in
            partial.union(path.bounds)
        }
        for point in mappedIsolatedPoints {
            contentBounds = contentBounds.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        contentMapRect = contentBounds
        super.init()
    }

    private static func bounds(for points: [MKMapPoint]) -> MKMapRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return MKMapRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }
}

final class ExplorationOverlayRenderer: MKOverlayRenderer {
    private var explorationOverlay: ExplorationOverlay {
        overlay as! ExplorationOverlay
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlay = explorationOverlay
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(overlay.referenceLatitude)
        let outerMapRadius = 100 * pointsPerMeter
        let dirtyRect = mapRect.insetBy(dx: -outerMapRadius, dy: -outerMapRadius)
        let visiblePaths = overlay.paths.filter { $0.bounds.intersects(dirtyRect) }
        let visiblePoints = overlay.isolatedPoints.filter { dirtyRect.contains($0) }

        if overlay.showFog {
            context.saveGState()
            context.setBlendMode(.normal)
            context.setFillColor(
                UIColor(red: 0.015, green: 0.025, blue: 0.055, alpha: 0.66).cgColor
            )
            context.fill(rect(for: mapRect))
            context.restoreGState()

            context.saveGState()
            context.setBlendMode(.destinationOut)
            let featherSteps = 18
            for step in 0..<featherSteps {
                let progress = CGFloat(step) / CGFloat(featherSteps - 1)
                let diameter = 220 - Double(progress) * 120
                let alpha = 0.025 + progress * 0.045
                clear(
                    paths: visiblePaths,
                    points: visiblePoints,
                    diameterMeters: diameter,
                    alpha: alpha,
                    context: context
                )
            }
            context.setBlendMode(.clear)
            clear(
                paths: visiblePaths,
                points: visiblePoints,
                diameterMeters: 100,
                alpha: 1,
                context: context
            )
            context.restoreGState()
        }

        if overlay.showTrack {
            context.saveGState()
            context.setBlendMode(.normal)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(10.0 / zoomScale)
            for path in visiblePaths {
                add(path: path.points, to: context)
                context.strokePath()
            }
            context.setStrokeColor(UIColor.systemOrange.cgColor)
            context.setLineWidth(3.5 / zoomScale)
            for path in visiblePaths {
                add(path: path.points, to: context)
                context.strokePath()
            }
            context.restoreGState()
        }
    }

    private func clear(
        paths: [ExplorationOverlay.Path],
        points: [MKMapPoint],
        diameterMeters: Double,
        alpha: CGFloat,
        context: CGContext
    ) {
        let lineWidth = diameterMeters
            * MKMapPointsPerMeterAtLatitude(explorationOverlay.referenceLatitude)
        context.setAlpha(alpha)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setFillColor(UIColor.black.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for path in paths {
            add(path: path.points, to: context)
            context.strokePath()
        }

        let radius = lineWidth / 2
        for mapPoint in points {
            let point = self.point(for: mapPoint)
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: lineWidth, height: lineWidth))
        }
    }

    private func add(path points: [MKMapPoint], to context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: point(for: first))
        for mapPoint in points.dropFirst() {
            context.addLine(to: point(for: mapPoint))
        }
    }
}
