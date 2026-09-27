import Foundation

/// Per-navigation data only. Never reconstruct this from the permanent footprint library.
struct RoadbookJourney: Codable, Sendable {
    struct Fix: Codable, Sendable {
        let point: RoadbookPoint
        let timestamp: Date
        let accuracy: Double
        let startsSegment: Bool
    }
    struct Coverage: Codable, Sendable {
        var lower: Double
        var upper: Double
    }
    let id: UUID
    private(set) var fixes: [Fix] = []
    private(set) var covered: [Coverage] = []
    private(set) var distance = 0.0
    private(set) var elapsed: TimeInterval = 0
    private(set) var started = false
    private var clock: Date?
    private var previousMatch: Double?
    private var breakPending = true

    private enum CodingKeys: String, CodingKey {
        case id, fixes, covered, distance, elapsed, started
    }
    init() { id = UUID() }

    mutating func begin(at date: Date) {
        guard !started else { return }
        started = true; clock = date; previousMatch = nil
    }
    mutating func updateClock(_ date: Date) {
        guard started else { return }
        if let clock { elapsed += max(0, date.timeIntervalSince(clock)) }
        clock = date
    }
    mutating func resume(at date: Date) {
        clock = started ? date : nil
        breakPending = true; previousMatch = nil
    }
    mutating func breakTrace() { breakPending = true; previousMatch = nil }

    /// Returns true only for a new, usable sample; stopped jitter does not add distance.
    mutating func append(_ point: RoadbookPoint, at date: Date, accuracy: Double,
                         matchedMeters: Double?, course: RoadbookCourse) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude), (-180...180).contains(point.longitude),
              accuracy.isFinite, (0...40).contains(accuracy) else { breakTrace(); return false }
        var segmentStart = breakPending
        var meters = 0.0
        if let last = fixes.last {
            let seconds = date.timeIntervalSince(last.timestamp)
            guard seconds > 0 else { return false }
            meters = RoadbookCourse.distance(last.point, point)
            if seconds > 30 { segmentStart = true }
            guard seconds > 30 || meters / seconds <= 45 else { breakTrace(); return false }
            if !segmentStart {
                guard meters >= max(5, min(20, (last.accuracy + accuracy) * 0.4)) else { return false }
            }
        } else { segmentStart = true }

        if started, !segmentStart {
            distance += meters
            if let previousMatch, let matchedMeters {
                let lower = min(previousMatch, matchedMeters), upper = max(previousMatch, matchedMeters)
                // No blanket [0, progress] coloring: a skipped bend must remain blue.
                if upper - lower <= meters * 1.35 + 5, upper > lower {
                    let samples = max(1, Int(ceil((upper - lower) / 10)))
                    let chord = RoadbookCourse(points: [fixes.last!.point, point])
                    let followsRoadbook = (0...samples).allSatisfy { index in
                        chord.match(course.point(at: lower + (upper - lower) * Double(index) / Double(samples)), previous: nil).error <= 20
                    }
                    if followsRoadbook { insertCoverage(lower: lower, upper: upper) }
                }
            }
        }
        fixes.append(Fix(point: point, timestamp: date, accuracy: accuracy, startsSegment: segmentStart))
        previousMatch = matchedMeters; breakPending = false
        return true
    }
    private mutating func insertCoverage(lower: Double, upper: Double) {
        var merged: [Coverage] = []
        for range in (covered + [Coverage(lower: lower, upper: upper)]).sorted(by: { $0.lower < $1.lower }) {
            if let last = merged.last, range.lower <= last.upper + 0.5 {
                merged[merged.count - 1].upper = max(last.upper, range.upper)
            } else { merged.append(range) }
        }
        covered = merged
    }
    func remainingSeconds(for remaining: Double) -> TimeInterval? {
        guard started, elapsed >= 20, distance >= 30, remaining.isFinite else { return nil }
        return max(0, remaining) * elapsed / distance
    }
    var traceSegments: [[RoadbookPoint]] {
        var segments: [[RoadbookPoint]] = []
        for fix in fixes {
            if fix.startsSegment || segments.isEmpty { segments.append([fix.point]) }
            else { segments[segments.count - 1].append(fix.point) }
        }
        return segments
    }
    func coveredSegments(on course: RoadbookCourse) -> [[RoadbookPoint]] {
        covered.map { range in
            [course.point(at: range.lower)] + zip(course.points, course.cumulative)
                .filter { $0.1 > range.lower && $0.1 < range.upper }.map(\.0)
                + [course.point(at: range.upper)]
        }
    }
}
