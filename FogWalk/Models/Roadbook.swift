import Foundation

struct RoadbookPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    var geo: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
}

struct RoadbookWaypoint: Codable, Identifiable, Sendable {
    var id = UUID()
    let name: String
    let point: RoadbookPoint
}

struct Roadbook: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let importedAt: Date
    let fingerprint: String
    let points: [RoadbookPoint]
    let waypoints: [RoadbookWaypoint]
    var isLoop: Bool
    var deletedAt: Date?
    var importWarning: String? = nil
    var distance: Double { zip(points, points.dropFirst()).reduce(0) { $0 + RoadbookCourse.distance($1.0, $1.1) } }
    var gap: Double { guard let a = points.first, let b = points.last else { return 0 }; return RoadbookCourse.distance(a,b) }
}

enum RoadbookError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct RoadbookTurn: Identifiable, Sendable {
    let id: Int
    let meters: Double
    let angle: Double
    var instruction: String { angle > 0 ? "沿路线右转" : "沿路线左转" }
    var symbol: String { angle > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left" }
}

struct RoadbookCourse: Sendable {
    let points: [RoadbookPoint]
    let cumulative: [Double]
    let turns: [RoadbookTurn]
    var length: Double { cumulative.last ?? 0 }

    init(points: [RoadbookPoint]) {
        self.points = points
        var lengths = [0.0]
        if points.count > 1 {
            for i in 1..<points.count { lengths.append(lengths.last! + Self.distance(points[i-1], points[i])) }
        }
        cumulative = lengths
        var candidates: [RoadbookTurn] = []
        if points.count > 2 {
            for i in 1..<(points.count-1) {
                let before = Self.interpolate(points, lengths, max(0,lengths[i]-25))
                let after = Self.interpolate(points, lengths, min(lengths.last!,lengths[i]+25))
                let angle = Self.signedAngle(Self.bearing(points[i],after)-Self.bearing(before,points[i]))
                guard abs(angle) >= 40 else { continue }
                let turn = RoadbookTurn(id:i, meters:lengths[i],angle:angle)
                if let last = candidates.last, turn.meters-last.meters < 35 {
                    if abs(turn.angle)>abs(last.angle) { candidates[candidates.count-1] = turn }
                } else { candidates.append(turn) }
            }
        }
        turns = candidates
    }
    static func distance(_ a: RoadbookPoint,_ b: RoadbookPoint) -> Double {
        let r = Double.pi/180
        let h = pow(sin((b.latitude-a.latitude)*r/2),2) + cos(a.latitude*r)*cos(b.latitude*r)*pow(sin((b.longitude-a.longitude)*r/2),2)
        return 6371000*2*atan2(sqrt(max(0,min(1,h))),sqrt(max(0,1-h)))
    }
    static func bearing(_ a: RoadbookPoint,_ b: RoadbookPoint) -> Double {
        let r = Double.pi/180, d = (b.longitude-a.longitude)*r
        return (atan2(sin(d)*cos(b.latitude*r),cos(a.latitude*r)*sin(b.latitude*r)-sin(a.latitude*r)*cos(b.latitude*r)*cos(d))*180/Double.pi+360).truncatingRemainder(dividingBy:360)
    }
    static func signedAngle(_ value: Double) -> Double {
        var v = value.truncatingRemainder(dividingBy:360)
        if v>180 { v-=360 }; if v < -180 { v+=360 }; return v
    }
    static func segment(_ c: [Double],at m: Double) -> Int {
        guard c.count > 1 else { return 0 }
        var low = 1, high = c.count-1
        while low < high { let mid=(low+high)/2; if c[mid] < m { low=mid+1 } else { high=mid } }
        return low
    }
    static func interpolate(_ p: [RoadbookPoint],_ c: [Double],_ meters: Double) -> RoadbookPoint {
        guard p.count>1 else { return p.first ?? RoadbookPoint(latitude:0,longitude:0) }
        let m=max(0,min(c.last!,meters)), i=segment(c,at:m)
        let f=(m-c[i-1])/max(0.001,c[i]-c[i-1])
        return RoadbookPoint(latitude:p[i-1].latitude+(p[i].latitude-p[i-1].latitude)*f,
                             longitude:p[i-1].longitude+(p[i].longitude-p[i-1].longitude)*f)
    }
    func point(at m: Double) -> RoadbookPoint { Self.interpolate(points,cumulative,m) }
    func heading(at m: Double) -> Double { Self.bearing(point(at:max(0,m-5)),point(at:min(length,m+12))) }
    func upcoming(at m: Double) -> [RoadbookTurn] { Array(turns.lazy.filter { $0.meters+8>m }.prefix(3)) }
    func match(_ fix: RoadbookPoint,previous: Double?,heading: Double? = nil,advance: Double = 300) -> (meters:Double,error:Double) {
        guard points.count>1 else { return (0,.infinity) }
        let sx=111195*cos(fix.latitude*Double.pi/180), sy=111195.0
        var best=(meters:previous ?? 0.0,error:Double.infinity), score=Double.infinity
        let first=previous.map { Self.segment(cumulative,at:max(0,$0-40)) } ?? 1
        let last=previous.map { Self.segment(cumulative,at:min(length,$0+advance)) } ?? points.count-1
        for i in first...max(first,last) {
            let ax=(points[i-1].longitude-fix.longitude)*sx, ay=(points[i-1].latitude-fix.latitude)*sy
            let dx=(points[i].longitude-points[i-1].longitude)*sx, dy=(points[i].latitude-points[i-1].latitude)*sy
            let t=max(0,min(1,-(ax*dx+ay*dy)/max(0.001,dx*dx+dy*dy)))
            let error=hypot(ax+t*dx,ay+t*dy), m=cumulative[i-1]+t*(cumulative[i]-cumulative[i-1])
            let penalty=heading.map { abs(Self.signedAngle(Self.bearing(points[i-1],points[i])-$0))/180*12 } ?? 0
            if error+penalty < score { score=error+penalty; best=(m,error) }
        }
        return best
    }
    /// Only used after the user confirms that the saved roadbook is a loop.
    func startingLoop(at meters: Double) -> RoadbookCourse {
        guard points.count>2 else { return self }
        let m=max(0,min(length,meters)), i=Self.segment(cumulative,at:m), p=point(at:m)
        var result=[p]
        result.append(contentsOf:points[i...])
        if let last=result.last, Self.distance(last,points[0])>0.5 { result.append(points[0]) }
        if i>1 { result.append(contentsOf:points[1..<i]) }
        result.append(p)
        return RoadbookCourse(points:result)
    }
}

struct RoadbookAlerts {
    private var delivered=Set<String>()
    mutating func update(course:RoadbookCourse,meters:Double,onRoute:Bool) -> String? {
        guard onRoute, let turn=course.upcoming(at:meters).first else { return nil }
        let remaining=turn.meters-meters
        guard remaining>0, remaining<=100 else { return nil }
        let threshold=remaining<=50 ? 50:100, key="\(turn.id):\(threshold)"
        guard delivered.insert(key).inserted else { return nil }
        if threshold==50 { delivered.insert("\(turn.id):100") }
        return "前方\(threshold)米，\(turn.instruction)"
    }
}
