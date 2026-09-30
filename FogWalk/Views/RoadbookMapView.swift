import SwiftUI
@preconcurrency import MapKit

struct RoadbookMapView: UIViewRepresentable {
    let points: [RoadbookPoint]
    var waypoints: [RoadbookWaypoint] = []
    var position: RoadbookPoint?
    var heading = 0.0
    var overview = true
    var showPoints = false
    var nextTurn: RoadbookPoint?
    var entryPoint: RoadbookPoint?
    var approachPoints: [RoadbookPoint] = []
    var coveredSegments: [[RoadbookPoint]] = []
    var actualSegments: [[RoadbookPoint]] = []
    var recenterRequest = 0
    var zoomRequest = 0
    var positionFraction = 0.5
    var bottomOverlayInset = 0.0
    var onInteraction: (() -> Void)?
    var onSelectEntry: ((Double) -> Void)?

    func makeUIView(context: Context) -> RoadbookMapContainer { RoadbookMapContainer() }
    func updateUIView(_ view: RoadbookMapContainer, context: Context) {
        view.update(self)
    }
}

final class RoadbookMapContainer: UIView, MKMapViewDelegate, UIGestureRecognizerDelegate {
    let map = MKMapView()
    let ink = RoadbookInk()
    private var lastOverview: Bool?
    private var lastPoints: [RoadbookPoint] = []
    private var configuration: RoadbookMapView?
    private var browsing = false
    private var recenterRequest = 0
    private var zoomRequest = 0
    private var followDistance = 650.0
    override init(frame: CGRect) {
        super.init(frame: frame)
        map.delegate = self; map.showsCompass = false; map.isPitchEnabled = false
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        addSubview(map); addSubview(ink); ink.map = map; ink.isUserInteractionEnabled = false
        ink.backgroundColor = .clear
        clipsToBounds = true
        for recognizer in [UIPanGestureRecognizer(target: self, action: #selector(interacted(_:))), UIPinchGestureRecognizer(target: self, action: #selector(interacted(_:)))] {
            recognizer.delegate = self; recognizer.cancelsTouchesInView = false; map.addGestureRecognizer(recognizer)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(selected(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false; map.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); layoutMap(); ink.frame = bounds
        if let configuration { updateCamera(configuration, force: lastOverview == nil) }
        ink.setNeedsDisplay()
    }
    func update(_ value: RoadbookMapView) {
        configuration = value
        layoutMap()
        ink.points = value.points; ink.position = value.position; ink.heading = value.heading
        ink.overview = value.overview; ink.showPoints = value.showPoints; ink.nextTurn = value.nextTurn
        ink.entryPoint = value.entryPoint; ink.approachPoints = value.approachPoints
        ink.coveredSegments = value.coveredSegments; ink.actualSegments = value.actualSegments
        if value.points != lastPoints {
            lastOverview = nil; lastPoints = value.points
            map.removeAnnotations(map.annotations)
            for waypoint in value.waypoints {
                let pin = MKPointAnnotation(); pin.title = waypoint.name
                pin.coordinate = ChinaCoordinateTransform.mapCoordinate(for: waypoint.point.geo).clCoordinate
                map.addAnnotation(pin)
            }
        }
        map.isScrollEnabled = true; map.isZoomEnabled = true; map.isRotateEnabled = true
        let recentered = recenterRequest != value.recenterRequest
        if recentered { browsing = false; recenterRequest = value.recenterRequest }
        if zoomRequest != value.zoomRequest {
            let factor = value.zoomRequest > zoomRequest ? 0.65 : 1.5
            zoomRequest = value.zoomRequest
            let camera = map.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = min(100_000, max(100, camera.centerCoordinateDistance * factor))
            followDistance = camera.centerCoordinateDistance
            map.setCamera(camera, animated: false)
        }
        updateCamera(value, force: recentered || lastOverview != value.overview)
        ink.setNeedsDisplay()
    }
    private func layoutMap() {
        map.frame = bounds
        let inset = configuration?.bottomOverlayInset ?? 0
        guard let value = configuration, !value.overview, value.position != nil else {
            map.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
            return
        }
        // MapKit rotates around its inset viewport center. Place that center
        // at the rider's screen anchor while keeping the camera target at GPS.
        let shift = bounds.height * (2 * min(0.85, max(0.15, value.positionFraction)) - 1)
        map.layoutMargins = UIEdgeInsets(top: inset + max(0, shift), left: 0,
                                        bottom: inset + max(0, -shift), right: 0)
    }
    private func updateCamera(_ value: RoadbookMapView, force: Bool) {
        guard bounds.width > 0, bounds.height > 0, !value.points.isEmpty else { return }
        guard !browsing else { return }
        if value.overview || value.position == nil {
            if force {
                var rect = MKMapRect.null
                for p in value.points + value.approachPoints + (value.position.map { [$0] } ?? []) {
                    let m = MKMapPoint(ChinaCoordinateTransform.mapCoordinate(for: p.geo).clCoordinate)
                    rect = rect.union(MKMapRect(x: m.x, y: m.y, width: 1, height: 1))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: value.onInteraction == nil ? 55 : 170, left: 35, bottom: 65, right: 35), animated: false)
            }
        } else if let position = value.position {
            let coordinate = ChinaCoordinateTransform.mapCoordinate(for: position.geo).clCoordinate
            let camera = MKMapCamera(lookingAtCenter: coordinate, fromDistance: followDistance, pitch: 0, heading: value.heading)
            map.setCamera(camera, animated: false)
        }
        lastOverview = value.overview
    }
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { ink.setNeedsDisplay() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func interacted(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began {
            browsing = true
            configuration?.onInteraction?()
        }
        if gesture.state == .ended { followDistance = min(100_000, max(100, map.camera.centerCoordinateDistance)) }
    }
    @objc private func selected(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let value = configuration, let select = value.onSelectEntry, value.points.count > 1 else { return }
        let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
        let mapped = RoadbookCourse(points: value.points.map { let c = ChinaCoordinateTransform.mapCoordinate(for: $0.geo); return RoadbookPoint(latitude: c.latitude, longitude: c.longitude) })
        let match = mapped.match(RoadbookPoint(latitude: coordinate.latitude, longitude: coordinate.longitude), previous: nil)
        let i = RoadbookCourse.segment(mapped.cumulative, at: match.meters)
        let fraction = (match.meters-mapped.cumulative[i-1]) / max(0.001, mapped.cumulative[i]-mapped.cumulative[i-1])
        let original = RoadbookCourse(points: value.points)
        select(original.cumulative[i-1] + fraction * (original.cumulative[i]-original.cumulative[i-1]))
    }
}

/// A CPU overlay also remains visible in VMs without working Metal tile rendering.
final class RoadbookInk: UIView {
    weak var map: MKMapView?
    var points: [RoadbookPoint] = []
    var position: RoadbookPoint?
    var heading = 0.0
    var overview = true
    var showPoints = false
    var nextTurn: RoadbookPoint?
    var entryPoint: RoadbookPoint?
    var approachPoints: [RoadbookPoint] = []
    var coveredSegments: [[RoadbookPoint]] = []
    var actualSegments: [[RoadbookPoint]] = []
    override func draw(_ rect: CGRect) {
        guard let map, let ctx = UIGraphicsGetCurrentContext(), points.count > 1 else { return }
        func screen(_ p: RoadbookPoint) -> CGPoint {
            map.convert(ChinaCoordinateTransform.mapCoordinate(for: p.geo).clCoordinate, toPointTo: self)
        }
        let path = UIBezierPath()
        for (i, p) in points.enumerated() {
            if i == 0 { path.move(to: screen(p)) } else { path.addLine(to: screen(p)) }
        }
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        UIColor.white.setStroke(); path.lineWidth = overview ? 7 : 12; path.stroke()
        UIColor.systemBlue.setStroke(); path.lineWidth = overview ? 4 : 8; path.stroke()
        func drawSegments(_ segments: [[RoadbookPoint]], color: UIColor, width: CGFloat) {
            color.setStroke()
            for segment in segments where segment.count > 1 {
                let line = UIBezierPath()
                line.move(to: screen(segment[0]))
                for point in segment.dropFirst() { line.addLine(to: screen(point)) }
                line.lineJoinStyle = .round; line.lineCapStyle = .round; line.lineWidth = width
                line.stroke()
            }
        }
        drawSegments(coveredSegments, color: .systemGray, width: overview ? 4 : 8)
        if approachPoints.count > 1 {
            let approach = UIBezierPath()
            for (i,p) in approachPoints.enumerated() { if i == 0 { approach.move(to: screen(p)) } else { approach.addLine(to: screen(p)) } }
            approach.lineWidth = 6; approach.lineJoinStyle = .round; UIColor.systemMint.setStroke(); approach.stroke()
        }
        drawSegments(actualSegments, color: .systemOrange, width: overview ? 2 : 3)
        if showPoints {
            UIColor.systemIndigo.setFill()
            for p in points { let s = screen(p); UIBezierPath(ovalIn: CGRect(x: s.x-3, y: s.y-3, width: 6, height: 6)).fill() }
        }
        for (i, p) in [points.first!, points.last!].enumerated() {
            let s = screen(p); (i == 0 ? UIColor.systemGreen : UIColor.systemRed).setFill()
            UIBezierPath(ovalIn: CGRect(x: s.x-7, y: s.y-7, width: 14, height: 14)).fill()
        }
        if let nextTurn {
            let s = screen(nextTurn); UIColor.systemOrange.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: s.x-12, y: s.y-12, width: 24, height: 24)); ring.lineWidth = 4; ring.stroke()
        }
        if let entryPoint {
            let s = screen(entryPoint)
            UIImage(systemName: "flag.circle.fill")?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: s.x-18, y: s.y-36, width: 36, height: 36))
        }
        guard let position else { return }
        let s = screen(position)
        ctx.saveGState(); ctx.translateBy(x: s.x, y: s.y)
        ctx.rotate(by: CGFloat((heading-map.camera.heading) * .pi / 180))
        if overview { ctx.scaleBy(x: 0.7, y: 0.7) }
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.18).cgColor)
        UIImage(systemName: "location.north.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: -16, y: -19, width: 32, height: 38))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        UIImage(systemName: "location.north.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal).draw(in: CGRect(x: -12, y: -15, width: 24, height: 30))
        ctx.restoreGState()
    }
}
