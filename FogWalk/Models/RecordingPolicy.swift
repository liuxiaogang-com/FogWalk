import Foundation
import CoreLocation

enum RecordingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal = "正常"
    case saver = "省电"
    var id: Self { self }
    var minimumInterval: TimeInterval { self == .normal ? 5 : 20 }
    var minimumDistance: Double { self == .normal ? 10 : 40 }
    var stationaryDelay: TimeInterval { self == .normal ? 120 : 90 }
}

enum MotionState: String, Sendable {
    case unknown = "运动状态待确认", stationary = "静止", walking = "步行", running = "跑步"
    case cycling = "骑行", automotive = "乘车", moving = "移动中"
    var isMoving: Bool { self != .stationary && self != .unknown }
}

struct RecordingPolicy: Sendable {
    private(set) var motion: MotionState = .unknown
    private(set) var stationarySince: Date?
    private(set) var lastAccepted: TrackPoint?
    private var previousFix: TrackPoint?

    mutating func updateMotion(_ value: MotionState, confident: Bool, now: Date) {
        guard confident else { return }
        motion = value
        if value == .stationary { stationarySince = stationarySince ?? now }
        else { stationarySince = nil }
    }

    func isResting(mode: RecordingMode, now: Date) -> Bool {
        guard let stationarySince else { return false }
        return now.timeIntervalSince(stationarySince) >= mode.stationaryDelay
    }

    mutating func accept(_ point: TrackPoint, mode: RecordingMode, now: Date, maximumAge: TimeInterval = 30) -> Bool {
        let age = now.timeIntervalSince(point.timestamp)
        guard age >= -5, age <= maximumAge, point.horizontalAccuracy >= 0,
              point.horizontalAccuracy <= (mode == .normal ? 65 : 100),
              point.coordinate.latitude.isFinite, point.coordinate.longitude.isFinite,
              (-90...90).contains(point.coordinate.latitude), (-180...180).contains(point.coordinate.longitude) else { return false }
        if let previousFix {
            let dt = point.timestamp.timeIntervalSince(previousFix.timestamp)
            guard dt > 0 else { return false }
            let distance = TrackProcessor.distanceMeters(from: previousFix.coordinate, to: point.coordinate)
            guard distance / dt <= TrackProcessor.maximumPlausibleSpeed else { return false }
            let reliableMovement = distance > max(15, previousFix.horizontalAccuracy + point.horizontalAccuracy)
            if point.speed >= 0.8 || reliableMovement {
                if !motion.isMoving { motion = .moving }
                stationarySince = nil
            } else if point.speed >= 0 && point.speed < 0.4 && distance < max(12, point.horizontalAccuracy) {
                motion = .stationary
                stationarySince = stationarySince ?? now
            }
        }
        previousFix = point
        guard let previous = lastAccepted else { lastAccepted = point; return true }
        let interval = point.timestamp.timeIntervalSince(previous.timestamp)
        let distance = TrackProcessor.distanceMeters(from: previous.coordinate, to: point.coordinate)
        let uncertainty = (previous.horizontalAccuracy + point.horizontalAccuracy) * 0.4
        guard interval >= mode.minimumInterval,
              distance >= max(mode.minimumDistance, uncertainty) else { return false }
        lastAccepted = point
        return true
    }
}

struct RecordingCheckpoint: Codable, Equatable, Sendable {
    let journalID: String
    let rowID: Int64
}

struct RecordedBatch: Sendable {
    let checkpoint: RecordingCheckpoint
    let points: [TrackPoint]
}
