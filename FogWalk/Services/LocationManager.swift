import Foundation
import CoreLocation
import CoreMotion
import UIKit

@MainActor
final class LocationManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentCoordinate: GeoCoordinate?
    @Published private(set) var currentCoordinateDate: Date?
    @Published private(set) var isRecording = false
    @Published private(set) var mode: RecordingMode
    @Published private(set) var status = "未开始记录"
    @Published private(set) var motionState: MotionState = .unknown
    @Published private(set) var latestFixDate: Date?
    @Published private(set) var latestAccuracy: Double?
    @Published private(set) var savedPointCount = 0
    @Published private(set) var motionAssistanceEnabled: Bool
    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var reducedAccuracy = false
    var onSavedPoints: (() -> Void)?
    let recordingStore: RecordingStore
    private let manager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let preferences: UserDefaults
    private var policy = RecordingPolicy()
    @Published private(set) var wantsRecording = false
    private var standardRunning = false
    private var isBackground = false
    private var writeTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var configuredResting: Bool?
    private var pendingPoints: [TrackPoint] = []
    private var wakeMonitoringUnavailable = false
    private let wakeRegionID = "FogWalk.recording.resume"

    init(preferences: UserDefaults = .standard, recordingStore: RecordingStore = RecordingStore()) {
        self.preferences = preferences
        self.recordingStore = recordingStore
        mode = RecordingMode(rawValue: preferences.string(forKey: "recording-mode-v1") ?? "") ?? .normal
        motionAssistanceEnabled = preferences.bool(forKey: "motion-assistance-v1")
        savedPointCount = preferences.integer(forKey: "recording-session-count-v1")
        authorizationStatus = manager.authorizationStatus
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            currentCoordinate = GeoCoordinate(latitude: 31.2304, longitude: 121.4737)
            currentCoordinateDate = Date()
        }
        #endif
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    func requestCurrentLocation() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { return }
        #endif
        switch authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !standardRunning {
                if !isRecording { status = "正在获取当前位置…" }
                manager.requestLocation()
            }
        default: errorMessage = "定位权限未开启，请在系统设置中允许位置访问。"
        }
    }

    func setMode(_ newMode: RecordingMode) {
        mode = newMode
        preferences.set(mode.rawValue, forKey: "recording-mode-v1")
        configuredResting = nil
        if isRecording { applyPolicy() }
    }

    func setMotionAssistance(_ enabled: Bool) {
        motionAssistanceEnabled = enabled
        preferences.set(enabled, forKey: "motion-assistance-v1")
        motionManager.stopActivityUpdates()
        evaluationTask?.cancel()
        policy.updateMotion(.unknown, confident: true, now: Date())
        motionState = .unknown
        configuredResting = nil
        if isRecording {
            startMotionAssistanceIfEnabled()
            applyPolicy()
        }
    }

    func startRecording() {
        guard !wantsRecording else { return }
        wantsRecording = true
        preferences.set(true, forKey: "recording-enabled-v1")
        errorMessage = nil
        policy = RecordingPolicy()
        wakeMonitoringUnavailable = false
        savedPointCount = 0
        preferences.set(0, forKey: "recording-session-count-v1")
        if authorizationStatus == .notDetermined {
            status = "等待定位授权"
            manager.requestWhenInUseAuthorization()
        } else { beginAuthorizedRecording() }
    }

    func requestAlwaysAccess() {
        if authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        else if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    func stopRecording() {
        wantsRecording = false
        preferences.set(false, forKey: "recording-enabled-v1")
        stopServices()
        status = pendingPoints.isEmpty ? "记录已结束" : "记录已结束，有位置等待保存"
        flushPendingPoints()
        if pendingPoints.isEmpty { onSavedPoints?() }
    }

    func restoreRecordingIfNeeded() {
        guard preferences.bool(forKey: "recording-enabled-v1"), !wantsRecording else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        wantsRecording = true
        beginAuthorizedRecording()
    }

    func setBackground(_ background: Bool) {
        isBackground = background
        if background {
            evaluationTask?.cancel()
            flushPendingPoints()
        } else if isRecording {
            reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            policy.updateMotion(.unknown, confident: true, now: Date())
            configuredResting = nil
            applyPolicy()
        }
    }

    private func beginAuthorizedRecording() {
        guard wantsRecording, !isRecording else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            status = "无法记录：请开启定位权限"
            errorMessage = "定位权限被拒绝或受限。"
            return
        }
        isRecording = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        configuredResting = nil
        if authorizationStatus == .authorizedAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        startMotionAssistanceIfEnabled()
        applyPolicy()
    }

    private func startMotionAssistanceIfEnabled() {
        guard motionAssistanceEnabled, isRecording else { return }
        if CMMotionActivityManager.isActivityAvailable() {
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                let confident = activity.confidence != .low
                let state: MotionState = activity.automotive ? .automotive : activity.cycling ? .cycling
                    : activity.running ? .running : activity.walking ? .walking : activity.stationary ? .stationary : .unknown
                Task { @MainActor [weak self] in self?.receivedMotion(state, confident: confident) }
            }
        }
    }

    private func receivedMotion(_ state: MotionState, confident: Bool) {
        guard isRecording, motionAssistanceEnabled else { return }
        policy.updateMotion(state, confident: confident, now: Date())
        motionState = policy.motion
        configuredResting = nil
        applyPolicy()
        // A timer improves foreground responsiveness only; background recovery uses OS events.
        evaluationTask?.cancel()
        if state == .stationary && confident && !isBackground {
            evaluationTask = Task { [weak self] in
                guard let delay = self?.mode.stationaryDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.applyPolicy()
            }
        }
    }

    private func applyPolicy() {
        guard isRecording else { return }
        let resting = policy.isResting(mode: mode, now: Date())
        guard configuredResting != resting || !standardRunning else { return }
        configuredResting = resting
        let always = authorizationStatus == .authorizedAlways
        manager.pausesLocationUpdatesAutomatically = always
        manager.activityType = policy.motion == .automotive ? .automotiveNavigation : .fitness
        manager.desiredAccuracy = resting ? (mode == .saver ? kCLLocationAccuracyKilometer : kCLLocationAccuracyHundredMeters)
            : (mode == .normal ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters)
        manager.distanceFilter = resting ? (mode == .normal ? 100 : 250) : (mode == .normal ? 15 : 60)
        if resting && mode == .saver && always && installWakeRegion() {
            manager.stopUpdatingLocation()
            standardRunning = false
            status = "静止省电，等待移动唤醒"
        } else {
            removeWakeRegion()
            if !standardRunning { manager.startUpdatingLocation(); standardRunning = true }
            status = resting ? "静止，低精度记录" : "\(mode.rawValue)模式记录中"
        }
    }

    @discardableResult
    private func installWakeRegion() -> Bool {
        guard authorizationStatus == .authorizedAlways,
              !wakeMonitoringUnavailable,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let coordinate = currentCoordinate else { return false }
        if manager.monitoredRegions.contains(where: { $0.identifier == wakeRegionID }) { return true }
        let radius = min(150, manager.maximumRegionMonitoringDistance)
        guard radius > 0 else { return false }
        let region = CLCircularRegion(center: coordinate.clCoordinate, radius: radius, identifier: wakeRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        return true
    }

    private func removeWakeRegion() {
        for region in manager.monitoredRegions where region.identifier == wakeRegionID { manager.stopMonitoring(for: region) }
    }

    private func stopServices() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        motionManager.stopActivityUpdates()
        evaluationTask?.cancel()
        removeWakeRegion()
        standardRunning = false
        configuredResting = nil
        isRecording = false
    }

    func flushPendingPoints() {
        guard writeTask == nil, !pendingPoints.isEmpty else { return }
        let batch = pendingPoints
        let batchMode = mode
        let context = isBackground ? "background" : "foreground"
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Save footprint batch", expirationHandler: nil)
        writeTask = Task {
            var succeeded = false
            do {
                let saved = try await recordingStore.append(batch, mode: batchMode, context: context)
                pendingPoints.removeFirst(batch.count)
                savedPointCount += saved
                preferences.set(savedPointCount, forKey: "recording-session-count-v1")
                storageErrorMessage = nil
                if !wantsRecording { status = "记录已结束" }
                succeeded = true
                onSavedPoints?()
                NSLog("FOGWALK_RECORD saved=%ld context=%@", saved, context)
            } catch {
                storageErrorMessage = error.localizedDescription
                status = "保存失败，请保持 App 打开并重试"
            }
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            writeTask = nil
            if succeeded && !pendingPoints.isEmpty { flushPendingPoints() }
        }
    }

    /// A backup must include every accepted point at the time it starts, or fail explicitly.
    func finishPendingWrites() async throws {
        flushPendingPoints()
        while let task = writeTask { await task.value }
        if !pendingPoints.isEmpty {
            throw NSError(domain: "FogWalk.Recording", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: storageErrorMessage ?? "仍有位置尚未保存，请重试。"])
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        NSLog("FOGWALK_LOCATION_AUTH status=%ld accuracy=%ld", authorizationStatus.rawValue, manager.accuracyAuthorization.rawValue)
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            stopServices()
            status = "定位权限已关闭，记录暂停"
            return
        }
        if wantsRecording {
            if isRecording {
                if authorizationStatus == .authorizedAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() {
                    manager.startMonitoringSignificantLocationChanges()
                } else { manager.stopMonitoringSignificantLocationChanges() }
                configuredResting = nil
                applyPolicy()
            } else { beginAuthorizedRecording() }
        } else if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let age = now.timeIntervalSince(location.timestamp)
            guard location.horizontalAccuracy >= 0, location.timestamp.timeIntervalSince(now) <= 5,
                  age <= (isRecording ? 300 : 30) else {
                if !isRecording { status = "尚未收到新鲜有效定位，请重试" }
                NSLog("FOGWALK_FIX_REJECTED age=%.1f accuracy=%.1f", age, location.horizontalAccuracy)
                continue
            }
            latestFixDate = location.timestamp
            latestAccuracy = location.horizontalAccuracy
            if location.horizontalAccuracy <= 100 && age <= 30 {
                currentCoordinate = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                currentCoordinateDate = location.timestamp
                errorMessage = nil
            }
            if !isRecording {
                status = location.horizontalAccuracy <= 100 ? "已获得当前位置" : "定位精度较低，请到开阔处重试"
            }
            NSLog("FOGWALK_FIX accuracy=%.1f age=%.1f recording=%d", location.horizontalAccuracy,
                  now.timeIntervalSince(location.timestamp), isRecording ? 1 : 0)
            guard isRecording else { continue }
            if !standardRunning {
                policy.updateMotion(.unknown, confident: true, now: now)
                configuredResting = nil
            }
            let point = TrackPoint(id: 0, timestamp: location.timestamp,
                coordinate: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                horizontalAccuracy: location.horizontalAccuracy, speed: location.speed, altitude: location.altitude, source: .recordedDevice)
            if policy.accept(point, mode: mode, now: now, maximumAge: 300) { pendingPoints.append(point) }
            motionState = policy.motion
            applyPolicy()
        }
        flushPendingPoints()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard isRecording else { return }
        standardRunning = false
        _ = installWakeRegion()
        status = "系统已暂停定位，等待移动或回到前台"
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        standardRunning = true
        status = "\(mode.rawValue)模式记录中"
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard isRecording, region.identifier == wakeRegionID else { return }
        policy.updateMotion(.unknown, confident: true, now: Date())
        configuredResting = nil
        applyPolicy()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard isRecording else { return }
        wakeMonitoringUnavailable = true
        policy.updateMotion(.unknown, confident: true, now: Date())
        configuredResting = nil
        applyPolicy()
        errorMessage = "移动唤醒不可用，已回退到持续低频定位。"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("FOGWALK_LOCATION_ERROR domain=%@ code=%ld", (error as NSError).domain, (error as NSError).code)
        guard (error as? CLError)?.code != .locationUnknown else {
            status = isRecording ? "等待有效 GPS 信号" : "暂未获得有效定位"
            return
        }
        errorMessage = error.localizedDescription
    }
}
