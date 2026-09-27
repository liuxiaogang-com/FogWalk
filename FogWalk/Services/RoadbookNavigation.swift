import Foundation
import Combine
import CoreLocation
import AVFoundation
@preconcurrency import MapKit

struct RoadbookSession: Codable {
    let book: Roadbook
    var points: [RoadbookPoint]
    var progress: Double
    var entered: Bool
    var entryMeters: Double? = nil
    var journey: RoadbookJourney? = nil
}

@MainActor
final class RoadbookNavigation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var session: RoadbookSession?
    @Published var position: RoadbookPoint?
    @Published var heading = 0.0
    @Published var progress = 0.0
    @Published var status = "等待定位"
    @Published var onRoute = false
    @Published var speed = 0.0
    @Published var finished = false
    @Published var isPreview = false
    @Published private(set) var journey = RoadbookJourney()
    var remainingTimeText: String {
        if isPreview { return "模拟移动 · 非真实骑行" }
        if finished { return "已完成全程" }
        if isApproaching { return "到达后确认开始，当前不计环线里程" }
        guard let seconds = journey.remainingSeconds(for: max(0, course.length - progress)) else { return "正在积累行程，估算剩余时间…" }
        return "按本次均速约 \(max(1, Int(ceil(seconds / 60)))) 分钟 · 含停留时间"
    }
    var recordingText: String {
        if let error = recorder?.storageErrorMessage { return "足迹保存失败：\(error)" }
        if finished { return "本次导航已结束 · 足迹保留在迷雾地图" }
        if lastFix == nil || Date().timeIntervalSince(lastFix!) > 15 || !hasUsableFix { return "等待有效定位后记录足迹" }
        return "正在记录本次轨迹，并保存到迷雾地图"
    }
    @Published private(set) var readyToStartLoop = false
    @Published private(set) var approachPoints: [RoadbookPoint] = []
    @Published private(set) var approachProgress = 0.0
    @Published private(set) var approachMessage = "等待定位后规划到入口的骑行路线"
    @Published private(set) var isPlanningApproach = false
    @Published var externalNavigationError: String?
    var isApproaching: Bool { session.map { $0.book.isLoop && !$0.entered && !isPreview } ?? false }
    var entryPoint: RoadbookPoint? { isApproaching ? course.points.first : nil }
    var entryDistance: Double? { guard let position, let entryPoint else { return nil }; return RoadbookCourse.distance(position, entryPoint) }
    var guidanceCourse: RoadbookCourse { isApproaching ? approachCourse : course }
    var guidanceProgress: Double { isApproaching ? approachProgress : progress }
    @Published var muted = UserDefaults.standard.bool(forKey: "roadbook.muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "roadbook.muted"); if muted { speech.stopSpeaking(at: .immediate) } }
    }
    @Published var voiceID = UserDefaults.standard.string(forKey: "roadbook.voice") ?? "" {
        didSet { UserDefaults.standard.set(voiceID, forKey: "roadbook.voice") }
    }
    var course = RoadbookCourse(points: [])
    var upcoming: [RoadbookTurn] { guidanceCourse.upcoming(at: guidanceProgress) }
    var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }.sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var background: CLBackgroundActivitySession?
    private var timer: Timer?
    private var alerts = RoadbookAlerts()
    private var lastFix: Date?
    private var hasUsableFix = false
    private var lastValidLocation: CLLocation?
    private let recorder: LocationManager?
    private var recorderChanges: AnyCancellable?
    private var lastSave = Date.distantPast
    private var lastOffRoute = Date.distantPast
    private var approachCourse = RoadbookCourse(points: [])
    private var approachAlerts = RoadbookAlerts()
    private var directions: MKDirections?
    private var planningTask: Task<Void, Never>?
    private var approachAttempted = false
    private var routeRequestID = UUID()
    private let saveURL: URL
    private let usesLiveSensors: Bool
    @Published var recoverable: RoadbookSession?

    init(directory: URL? = nil, usesLiveSensors: Bool = true, recorder: LocationManager? = nil) {
        self.usesLiveSensors = usesLiveSensors
        self.recorder = recorder
        saveURL = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roadbooks")).appendingPathComponent("navigation-v1.json")
        super.init()
        recorderChanges = recorder?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        manager.delegate = self
        speech.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Keep fresh fixes even while waiting motionless for entry confirmation.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        if let data = try? Data(contentsOf: saveURL) { recoverable = try? JSONDecoder().decode(RoadbookSession.self, from: data) }
    }
    func start(_ book: Roadbook, preview: Bool = false, entryMeters: Double? = nil) {
        if !isPreview { recorder?.endNavigationRecording(journey.id) }
        stopSensors()
        resetApproach()
        isPreview = preview; finished = false; progress = 0; position = nil; speed = 0
        alerts = RoadbookAlerts(); lastFix = nil; hasUsableFix = false; onRoute = false
        journey = RoadbookJourney(); lastValidLocation = nil
        course = RoadbookCourse(points: book.points)
        let entry = book.isLoop && !preview ? max(0, min(course.length, entryMeters ?? 0)) : nil
        if let entry { course = course.startingLoop(at: entry) }
        session = RoadbookSession(book: book, points: course.points, progress: 0, entered: false, entryMeters: entry)
        if preview {
            session?.entered = true; status = "路线预览 · 模拟移动"; onRoute = true
            tickPreview()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickPreview() }
            }
        } else { recorder?.beginNavigationRecording(journey.id); persist(); beginGPS() }
    }
    func resume() {
        guard let saved = recoverable, saved.points.count > 1 else { return }
        stopSensors(); resetApproach()
        session = saved; course = RoadbookCourse(points: saved.points); progress = saved.progress
        if !isPreview { recorder?.endNavigationRecording(journey.id) }
        journey = saved.journey ?? RoadbookJourney()
        lastValidLocation = nil
        journey.resume(at: Date())
        if saved.entered { journey.begin(at: Date()) }
        recorder?.beginNavigationRecording(journey.id)
        isPreview = false; finished = false; position = nil; speed = 0; onRoute = false; lastFix = nil; hasUsableFix = false; alerts = RoadbookAlerts()
        beginGPS()
    }
    private func beginGPS() {
        status = "等待准确定位"
        guard usesLiveSensors else { return }
        manager.requestWhenInUseAuthorization()
        activateGPS()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.journey.updateClock(Date())
                if self.lastFix.map({ Date().timeIntervalSince($0) > 15 }) ?? false {
                    self.onRoute = false; self.speed = 0; self.status = "定位暂时中断，等待新位置"
                    self.readyToStartLoop = false
                    self.journey.breakTrace()
                }
                self.persist()
            }
        }
    }
    private func activateGPS() {
        guard usesLiveSensors, session != nil, !isPreview, !finished else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if background == nil { background = CLBackgroundActivitySession() }
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation(); manager.startUpdatingHeading()
        case .denied, .restricted: status = "请在系统设置中允许定位后继续"; readyToStartLoop = false; onRoute = false
        default: break
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { activateGPS() }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "定位暂不可用：\(error.localizedDescription)"; onRoute = false; readyToStartLoop = false; hasUsableFix = false; journey.breakTrace() }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading value: CLHeading) {
        if speed < 1, value.headingAccuracy >= 0 { heading = value.trueHeading >= 0 ? value.trueHeading : value.magneticHeading }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) { receive(fix) }
    }
    private func receive(_ fix: CLLocation) {
        guard !isPreview, !finished, var current = session,
              abs(fix.timestamp.timeIntervalSinceNow) < 15 else { return }
        guard lastFix.map({ fix.timestamp > $0 }) ?? true else { return }
        guard CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy.isFinite,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 40 else {
            status = "定位精度不足，暂缓转弯提醒"; onRoute = false; speed = 0; readyToStartLoop = false; hasUsableFix = false; journey.breakTrace(); return
        }
        if let previous = lastValidLocation {
            let seconds = fix.timestamp.timeIntervalSince(previous.timestamp)
            if seconds > 0, seconds <= 30, fix.distance(from: previous) / seconds > 45 {
                status = "定位跳变，等待稳定位置"; hasUsableFix = false; onRoute = false; readyToStartLoop = false
                journey.breakTrace(); return
            }
        }
        lastValidLocation = fix
        position = RoadbookPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        hasUsableFix = true
        journey.updateClock(Date())
        let elapsed = lastFix.map { fix.timestamp.timeIntervalSince($0) } ?? 1
        lastFix = fix.timestamp; speed = max(0, fix.speed)
        if fix.course >= 0, speed >= 1 { heading = fix.course }
        let p = position!
        if !current.entered {
            if current.book.isLoop {
                recordFix(fix, matchedMeters: nil)
                updateApproach(p)
                return
            } else {
                let distance = RoadbookCourse.distance(p, course.points[0])
                guard distance <= 35 else { recordFix(fix, matchedMeters: nil); status = "请前往原起点 · 直线约 \(Int(distance)) 米"; return }
            }
            current.entered = true; session = current; progress = 0; persist()
            journey.begin(at: Date()); journey.breakTrace()
        }
        let match = course.match(p, previous: progress, heading: fix.course >= 0 ? fix.course : nil,
                                 advance: max(150, min(3000, max(0, elapsed) * 20 + 100)))
        onRoute = match.error <= 40
        recordFix(fix, matchedMeters: onRoute ? match.meters : nil)
        if onRoute {
            progress = max(progress, match.meters); status = "沿路书前进"
            if let text = alerts.update(course: course, meters: progress, onRoute: true) { speak(text) }
            if course.length - progress < 15, RoadbookCourse.distance(p, course.points.last!) < 25 {
                complete()
            }
        } else {
            status = "偏离路线约 \(Int(match.error)) 米 · 请查看地图返回"
            if Date().timeIntervalSince(lastOffRoute) > 45 { speak("已偏离路线，请查看地图返回"); lastOffRoute = Date() }
        }
        if Date().timeIntervalSince(lastSave) > 5 { persist() }
    }
    private func recordFix(_ fix: CLLocation, matchedMeters: Double?) {
        let point = RoadbookPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        guard journey.append(point, at: fix.timestamp, accuracy: fix.horizontalAccuracy,
                             matchedMeters: matchedMeters, course: course) else { return }
        recorder?.recordNavigationPoint(TrackPoint(id: 0, timestamp: fix.timestamp, coordinate: point.geo,
            horizontalAccuracy: fix.horizontalAccuracy, speed: fix.speed, altitude: fix.altitude, source: .recordedDevice), sessionID: journey.id)
    }
    private func updateApproach(_ point: RoadbookPoint) {
        let distance = RoadbookCourse.distance(point, course.points[0])
        let wasReady = readyToStartLoop
        readyToStartLoop = distance <= 35
        if readyToStartLoop {
            status = "已到入口，确认后开始环线"; onRoute = false
            if !wasReady { speak("已到达所选入口，请确认开始环线") }
        } else {
            status = "前往所选入口 · 直线约 \(Int(distance)) 米"
            if approachCourse.points.count > 1 {
                let match = approachCourse.match(point, previous: approachProgress)
                onRoute = match.error <= 40
                if onRoute {
                    approachProgress = max(approachProgress, match.meters)
                    if let prompt = approachAlerts.update(course: approachCourse, meters: approachProgress, onRoute: true) { speak(prompt) }
                } else { status = "已偏离入口路线，可重新规划" }
            }
            if !approachAttempted { planApproach() }
        }
    }
    func confirmLoopStart() {
        guard isApproaching, readyToStartLoop, let position, let lastFix,
              Date().timeIntervalSince(lastFix) <= 15,
              RoadbookCourse.distance(position, course.points[0]) <= 35 else { return }
        session?.entered = true; progress = 0; onRoute = true; status = "沿环线前进"
        journey.begin(at: Date()); journey.breakTrace()
        resetApproach(); alerts = RoadbookAlerts(); persist(); speak("开始环线导航")
    }
    private func resetApproach() {
        routeRequestID = UUID(); planningTask?.cancel(); planningTask = nil; directions?.cancel(); directions = nil
        approachAttempted = false; isPlanningApproach = false; readyToStartLoop = false
        approachPoints = []; approachProgress = 0; approachCourse = RoadbookCourse(points: [])
        approachAlerts = RoadbookAlerts(); approachMessage = "等待定位后规划到入口的骑行路线"
    }
    func planApproach() {
        if isApproaching, !isPlanningApproach, lastFix.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
            approachAttempted = false
            approachMessage = "正在更新当前位置…"
            refreshLocation()
            return
        }
        guard usesLiveSensors, isApproaching, !isPlanningApproach, let position, let destination = entryPoint,
              let lastFix, Date().timeIntervalSince(lastFix) <= 15 else { return }
        approachAttempted = true; isPlanningApproach = true; approachMessage = "正在规划到入口的骑行路线…"
        onRoute = false
        approachPoints = []; approachCourse = RoadbookCourse(points: []); approachProgress = 0; approachAlerts = RoadbookAlerts()
        let request = MKDirections.Request()
        request.source = MKMapItem(location: ChinaCoordinateTransform.mapCoordinate(for: position.geo).location, address: nil)
        request.destination = MKMapItem(location: ChinaCoordinateTransform.mapCoordinate(for: destination.geo).location, address: nil)
        request.transportType = .cycling
        let directions = MKDirections(request: request); self.directions = directions
        let requestID = UUID(); routeRequestID = requestID
        planningTask = Task { [weak self] in
            do {
                let response = try await directions.calculate()
                guard let self, !Task.isCancelled, self.routeRequestID == requestID, self.isApproaching else { return }
                guard let route = response.routes.first, route.polyline.pointCount > 1 else { throw RoadbookError.message("没有可用的骑行路线") }
                var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: route.polyline.pointCount)
                route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
                self.approachPoints = coordinates.map(Self.sourcePoint)
                self.approachCourse = RoadbookCourse(points: self.approachPoints)
                self.approachMessage = "绿色线路前往入口 · 蓝色为完整环线"
                self.isPlanningApproach = false
            } catch {
                guard let self, !Task.isCancelled, self.routeRequestID == requestID else { return }
                self.isPlanningApproach = false
                self.approachMessage = "Apple 骑行路线暂不可用，可用地图 App 前往入口；到达后返回确认开始。"
            }
        }
    }
    func refreshLocation() {
        guard usesLiveSensors, !isPreview, !finished, session != nil else { return }
        status = "正在更新当前位置…"
        manager.stopUpdatingLocation()
        activateGPS()
    }
    /// Invert our existing map-boundary transform for Apple route geometry.
    static func sourcePoint(_ coordinate: CLLocationCoordinate2D) -> RoadbookPoint {
        var guess = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        for _ in 0..<6 {
            let mapped = ChinaCoordinateTransform.mapCoordinate(for: guess)
            guess = GeoCoordinate(latitude: guess.latitude + coordinate.latitude-mapped.latitude,
                                  longitude: guess.longitude + coordinate.longitude-mapped.longitude)
        }
        return RoadbookPoint(latitude: guess.latitude, longitude: guess.longitude)
    }
    func openEntry(in app: NavigationApp) {
        guard let point = entryPoint else { return }
        let recommendation = ExploreRecommendation(title: "环线入口", subtitle: session?.book.name ?? "",
            coordinate: ChinaCoordinateTransform.mapCoordinate(for: point.geo), estimatedMinutes: 0,
            distanceMeters: entryDistance ?? 0, routeCoordinates: [], routeNoveltyRatio: 0, destinationNoveltyRatio: 0,
            mapItem: nil, isRouteVerified: false)
        persist()
        Task {
            do { try await ExternalNavigation.open(recommendation, in: app, travelMode: .cycling) }
            catch { externalNavigationError = error.localizedDescription }
        }
    }
    private func tickPreview() {
        guard !finished else { return }
        progress = min(course.length, progress + 12)
        position = course.point(at: progress); heading = course.heading(at: progress); speed = 12
        if let text = alerts.update(course: course, meters: progress, onRoute: true) { speak(text) }
        if progress >= course.length { complete() }
    }
    private func complete() {
        if !isPreview { journey.updateClock(Date()); recorder?.endNavigationRecording(journey.id) }
        finished = true; status = "已完成全程"; speak("已完成路书全程")
        stopSensors(); if !isPreview { clearSaved() }
    }
    func speak(_ text: String, preview: Bool = false) {
        guard usesLiveSensors, preview || !muted else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? voices.first(where: { $0.language == "zh-CN" }) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        speech.stopSpeaking(at: .immediate); speech.speak(utterance)
    }
    func checkpoint() { persist() }
    private func persist() {
        guard !isPreview, !finished, var value = session else { return }
        journey.updateClock(Date())
        value.progress = progress; value.journey = journey; session = value
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: saveURL, options: .atomic)
            recoverable = value; lastSave = Date()
        } catch { status = "进度保存失败：\(error.localizedDescription)" }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    private func clearSaved() { try? FileManager.default.removeItem(at: saveURL); recoverable = nil }
    private func stopSensors() {
        timer?.invalidate(); timer = nil
        manager.stopUpdatingLocation(); manager.stopUpdatingHeading()
        background?.invalidate(); background = nil
    }
    func end() {
        if !isPreview { journey.updateClock(Date()); recorder?.endNavigationRecording(journey.id) }
        resetApproach()
        stopSensors(); speech.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        if !isPreview { clearSaved() }; session = nil
    }
}
