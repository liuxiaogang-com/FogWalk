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
    var recenterCoordinate: GeoCoordinate?
    var recenterRequestID = 0
    var recenterSpanMeters: CLLocationDistance = 3_000
    var highlightedRoute: [GeoCoordinate] = []
    var destinationCoordinate: GeoCoordinate?
    var destinationMarkers: [ExploreMapDestination] = []
    var selectedDestinationID: UUID?
    var onDestinationSelection: ((UUID) -> Void)?
    var isLongPressSelectionEnabled = false
    var onLongPressSelection: ((GeoCoordinate) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = true
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = false
        // A dark base map keeps the revealed corridor legible without the
        // harsh white "light tube" effect produced by cutting a light map out
        // of a nearly black overlay.
        mapView.overrideUserInterfaceStyle = .dark
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .includingAll
        mapView.preferredConfiguration = configuration
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 12
        mapView.addGestureRecognizer(longPress)
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35, longitude: 105),
                latitudinalMeters: 4_500_000,
                longitudinalMeters: 4_500_000
            ),
            animated: false
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.isLongPressSelectionEnabled = isLongPressSelectionEnabled
        context.coordinator.onLongPressSelection = onLongPressSelection
        context.coordinator.onDestinationSelection = onDestinationSelection

        if context.coordinator.lastRecenterRequestID != recenterRequestID,
           let recenterCoordinate {
            context.coordinator.lastRecenterRequestID = recenterRequestID
            context.coordinator.hasPositionedMap = true
            mapView.setRegion(
                MKCoordinateRegion(
                    center: recenterCoordinate.clCoordinate,
                    latitudinalMeters: recenterSpanMeters,
                    longitudinalMeters: recenterSpanMeters
                ),
                animated: true
            )
        }

        if centersOnCurrentCoordinate,
           let liveCurrentCoordinate,
           !context.coordinator.hasAppliedLiveCenter {
            context.coordinator.hasAppliedLiveCenter = true
            context.coordinator.hasPositionedMap = true
            mapView.setRegion(
                MKCoordinateRegion(
                    center: liveCurrentCoordinate.clCoordinate,
                    latitudinalMeters: initialSpanMeters,
                    longitudinalMeters: initialSpanMeters
                ),
                animated: context.coordinator.overlayState != nil
            )
        }
        let state = OverlayState(
            revision: presentation.revision,
            fog: isFogVisible,
            track: isTrackVisible,
            route: highlightedRoute,
            destination: destinationCoordinate,
            destinationMarkers: destinationMarkers,
            selectedDestinationID: selectedDestinationID
        )
        if context.coordinator.overlayState != state {
            if !context.coordinator.overlays.isEmpty {
                mapView.removeOverlays(context.coordinator.overlays)
            }
            if !context.coordinator.annotations.isEmpty {
                mapView.removeAnnotations(context.coordinator.annotations)
            }
            var overlays = [MKOverlay]()
            if isFogVisible {
                overlays.append(
                    ExplorationOverlay(presentation: presentation, showFog: true, showTrack: false)
                )
            }
            if isTrackVisible {
                overlays.append(
                    ExplorationOverlay(presentation: presentation, showFog: false, showTrack: true)
                )
            }
            if highlightedRoute.count >= 2 {
                var coordinates = highlightedRoute.map(\.clCoordinate)
                overlays.append(MKPolyline(coordinates: &coordinates, count: coordinates.count))
            }
            context.coordinator.overlays = overlays
            context.coordinator.overlayState = state
            if let fogOverlay = overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showFog }) {
                mapView.addOverlay(fogOverlay, level: .aboveLabels)
            }
            if let trackOverlay = overlays.compactMap({ $0 as? ExplorationOverlay }).first(where: { $0.showTrack }) {
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

            if let routeOverlay = overlays.first(where: { $0 is MKPolyline }) {
                context.coordinator.hasPositionedMap = true
                let markerRect = destinationMarkers.reduce(MKMapRect.null) { partial, destination in
                    let point = MKMapPoint(destination.coordinate.clCoordinate)
                    let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
                    return partial.isNull ? pointRect : partial.union(pointRect)
                }
                let visibleRect = markerRect.isNull
                    ? routeOverlay.boundingMapRect
                    : routeOverlay.boundingMapRect.union(markerRect)
                mapView.setVisibleMapRect(
                    visibleRect,
                    edgePadding: UIEdgeInsets(top: 120, left: 38, bottom: 310, right: 38),
                    animated: true
                )
            } else if let destinationCoordinate {
                context.coordinator.hasPositionedMap = true
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: destinationCoordinate.clCoordinate,
                        latitudinalMeters: 3_500,
                        longitudinalMeters: 3_500
                    ),
                    animated: true
                )
            }
        }

        if !context.coordinator.hasPositionedMap,
           let coordinate = currentCoordinate ?? presentation.latestCoordinate {
            context.coordinator.hasPositionedMap = true
            if centersOnCurrentCoordinate {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: coordinate.clCoordinate,
                        latitudinalMeters: initialSpanMeters,
                        longitudinalMeters: initialSpanMeters
                    ),
                    animated: false
                )
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
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [MKOverlay] = []
        var annotations: [MKAnnotation] = []
        fileprivate var overlayState: OverlayState?
        var hasPositionedMap = false
        var hasAppliedLiveCenter = false
        var lastRecenterRequestID = 0
        var isLongPressSelectionEnabled = false
        var onLongPressSelection: ((GeoCoordinate) -> Void)?
        var onDestinationSelection: ((UUID) -> Void)?

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

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let destination = annotation as? ExploreDestinationAnnotation,
                  let id = destination.id else { return }
            onDestinationSelection?(id)
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}

fileprivate struct OverlayState: Equatable {
    let revision: Int
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
