import CoreLocation
import Combine
import Foundation

enum MapOrientation: String, CaseIterable, Identifiable {
    case northUp
    case phoneHeading

    var id: Self { self }
    var title: String { self == .northUp ? "北方朝上" : "手机朝向" }
    var icon: String { self == .northUp ? "safari" : "location.north.line.fill" }
}

/// Foreground map sensors never change the recorder's distance filter or write footprints.
@MainActor
final class HomeMapLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: GeoCoordinate?
    @Published private(set) var heading: Double?
    @Published private(set) var orientation: MapOrientation
    @Published private(set) var isFollowing = true
    @Published private(set) var message: String?
    @Published private(set) var recenterCoordinate: GeoCoordinate?
    @Published private(set) var recenterRequestID = 0
    private(set) var isActive = false
    private var coordinateDate: Date?
    private var freshnessTask: Task<Void, Never>?
    private let manager: CLLocationManager
    private let preferences: UserDefaults

    init(manager: CLLocationManager = CLLocationManager(), preferences: UserDefaults = .standard) {
        self.manager = manager
        self.preferences = preferences
        orientation = MapOrientation(rawValue: preferences.string(forKey: "home-map-orientation-v1") ?? "") ?? .northUp
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = false
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        heading = nil
        if active {
            expireLocation()
            startAuthorizedSensors()
            freshnessTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.expireLocation()
                }
            }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            freshnessTask?.cancel()
            freshnessTask = nil
            recenterCoordinate = nil
            coordinate = nil
        }
    }

    func toggleOrientation() {
        orientation = orientation == .northUp ? .phoneHeading : .northUp
        preferences.set(orientation.rawValue, forKey: "home-map-orientation-v1")
    }

    func requestRecenter() {
        // Center the exact location already displayed by the arrow. GPS keeps
        // updating independently; a camera action must not wait for another fix.
        if let coordinate {
            recenterCoordinate = coordinate
            recenterRequestID &+= 1
            isFollowing = true
            message = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            message = "请允许定位，当前位置出现后即可居中。"
        case .authorizedAlways, .authorizedWhenInUse:
            message = "尚未获得当前位置，位置出现后再点定位即可居中。"
        default:
            message = "定位权限未开启，请在系统设置中允许位置访问。"
        }
    }

    /// Gestures pause position following only; compass orientation stays active.
    func pauseFollowing() {
        isFollowing = false
    }

    private func startAuthorizedSensors() {
        guard isActive else { return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func expireLocation(now: Date = Date()) {
        if let coordinateDate, now.timeIntervalSince(coordinateDate) > 30 {
            coordinate = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startAuthorizedSensors()
        case .denied, .restricted:
            self.manager.stopUpdatingLocation()
            self.manager.stopUpdatingHeading()
            coordinate = nil
            coordinateDate = nil
            heading = nil
            isFollowing = false
            recenterCoordinate = nil
            message = "定位权限未开启，请在系统设置中允许位置访问。"
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isActive else { return }
        let now = Date()
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard CLLocationCoordinate2DIsValid(fix.coordinate),
                  fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100,
                  now.timeIntervalSince(fix.timestamp) <= 30,
                  fix.timestamp.timeIntervalSince(now) <= 5,
                  fix.timestamp >= (coordinateDate ?? .distantPast) else { continue }
            coordinate = ChinaCoordinateTransform.mapCoordinate(for:
                GeoCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude))
            coordinateDate = fix.timestamp
            message = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard isActive else { return }
        guard abs(newHeading.timestamp.timeIntervalSinceNow) <= 15 else { heading = nil; return }
        heading = Self.validHeading(trueHeading: newHeading.trueHeading, magneticHeading: newHeading.magneticHeading,
                                    accuracy: newHeading.headingAccuracy)
    }

    static func validHeading(trueHeading: Double, magneticHeading: Double, accuracy: Double) -> Double? {
        guard accuracy.isFinite, accuracy >= 0 else { return nil }
        let value = trueHeading >= 0 ? trueHeading : magneticHeading
        guard value.isFinite, value >= 0, value < 360 else { return nil }
        return value
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isActive else { return }
        if (error as? CLError)?.code == .locationUnknown {
            message = "正在等待有效 GPS 信号…"
        } else {
            message = "无法获取当前位置：\(error.localizedDescription)"
        }
    }
}
