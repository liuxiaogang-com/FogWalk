import Foundation
import MapKit

/// A compact raster of everywhere the user has explored. Track samples are
/// connected only when TrackProcessor considers the movement trustworthy, then
/// every point/segment is expanded to the configured visual exploration radius.
struct ExplorationGrid: Sendable, Codable {
    private struct Cell: Hashable, Sendable {
        let x: Int32
        let y: Int32
    }

    static let defaultExplorationRadiusMeters: Double = 50

    private let cells: Set<Cell>
    private let cellSizeMapPoints: Double
    private let mapPointsPerMeter: Double

    private enum CodingKeys: String, CodingKey { case cells, cellSizeMapPoints, mapPointsPerMeter }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var bytes = Data(capacity: cells.count * 8)
        for cell in cells {
            var x = cell.x.littleEndian
            var y = cell.y.littleEndian
            withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { bytes.append(contentsOf: $0) }
        }
        try container.encode(bytes, forKey: .cells)
        try container.encode(cellSizeMapPoints, forKey: .cellSizeMapPoints)
        try container.encode(mapPointsPerMeter, forKey: .mapPointsPerMeter)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .cells)
        cellSizeMapPoints = try container.decode(Double.self, forKey: .cellSizeMapPoints)
        mapPointsPerMeter = try container.decode(Double.self, forKey: .mapPointsPerMeter)
        guard data.count % 8 == 0, cellSizeMapPoints.isFinite, cellSizeMapPoints > 0,
              mapPointsPerMeter.isFinite, mapPointsPerMeter > 0 else { throw SnapshotError.invalidBytes }
        cells = data.withUnsafeBytes { bytes in
            var result = Set<Cell>(minimumCapacity: data.count / 8)
            for offset in stride(from: 0, to: data.count, by: 8) {
                result.insert(Cell(
                    x: Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)),
                    y: Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self))
                ))
            }
            return result
        }
    }

    init(
        points: [TrackPoint],
        cellSizeMeters: Double = 25,
        explorationRadiusMeters: Double = defaultExplorationRadiusMeters
    ) {
        let mapCoordinates = points.map {
            ChinaCoordinateTransform.mapCoordinate(for: $0.coordinate)
        }
        let referenceLatitude = mapCoordinates.last?.latitude ?? 35
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(referenceLatitude)
        let cellSize = max(1, cellSizeMeters * pointsPerMeter)
        var occupied = Set<Cell>()

        func fillExploredArea(around mapPoint: MKMapPoint) {
            Self.fillCells(
                around: mapPoint,
                radiusMeters: explorationRadiusMeters,
                cellSizeMapPoints: cellSize,
                mapPointsPerMeter: pointsPerMeter,
                into: &occupied
            )
        }

        for (index, coordinate) in mapCoordinates.enumerated() {
            let destination = MKMapPoint(coordinate.clCoordinate)
            fillExploredArea(around: destination)

            guard index > 0, TrackProcessor.canConnect(points[index - 1], points[index]) else {
                continue
            }
            let source = MKMapPoint(mapCoordinates[index - 1].clCoordinate)
            let distanceMapPoints = hypot(destination.x - source.x, destination.y - source.y)
            let sampleSpacing = max(1, 20 * pointsPerMeter)
            let sampleCount = max(1, Int(ceil(distanceMapPoints / sampleSpacing)))
            for step in 1..<sampleCount {
                let progress = Double(step) / Double(sampleCount)
                fillExploredArea(
                    around: MKMapPoint(
                        x: source.x + (destination.x - source.x) * progress,
                        y: source.y + (destination.y - source.y) * progress
                    )
                )
            }
        }

        cells = occupied
        cellSizeMapPoints = cellSize
        mapPointsPerMeter = pointsPerMeter
    }

    init(
        coordinates: [GeoCoordinate],
        cellSizeMeters: Double = 25,
        explorationRadiusMeters: Double = defaultExplorationRadiusMeters
    ) {
        let referenceLatitude = coordinates.last?.latitude ?? 35
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(referenceLatitude)
        let cellSize = max(1, cellSizeMeters * pointsPerMeter)
        var occupied = Set<Cell>()
        for coordinate in coordinates {
            Self.fillCells(
                around: MKMapPoint(coordinate.clCoordinate),
                radiusMeters: explorationRadiusMeters,
                cellSizeMapPoints: cellSize,
                mapPointsPerMeter: pointsPerMeter,
                into: &occupied
            )
        }
        cells = occupied
        cellSizeMapPoints = cellSize
        mapPointsPerMeter = pointsPerMeter
    }

    func isExplored(_ coordinate: GeoCoordinate) -> Bool {
        cells.contains(cell(for: MKMapPoint(coordinate.clCoordinate)))
    }

    func noveltyRatio(along coordinates: [GeoCoordinate]) -> Double {
        guard !coordinates.isEmpty else { return 0 }
        let samples = sampledRoute(coordinates, spacingMeters: 35)
        let unknownCount = samples.reduce(into: 0) { count, coordinate in
            if !isExplored(coordinate) { count += 1 }
        }
        return samples.isEmpty ? 0 : Double(unknownCount) / Double(samples.count)
    }

    /// Measures how much of the neighborhood around a destination is still
    /// unknown, rather than treating one unvisited coordinate as enough.
    func noveltyRatio(around coordinate: GeoCoordinate, radiusMeters: Double = 180) -> Double {
        let center = MKMapPoint(coordinate.clCoordinate)
        let sampleSpacing = 45 * mapPointsPerMeter
        let radiusMapPoints = radiusMeters * mapPointsPerMeter
        let stepCount = max(1, Int(ceil(radiusMapPoints / sampleSpacing)))
        var total = 0
        var unknown = 0
        for xStep in -stepCount...stepCount {
            for yStep in -stepCount...stepCount {
                let dx = Double(xStep) * sampleSpacing
                let dy = Double(yStep) * sampleSpacing
                guard hypot(dx, dy) <= radiusMapPoints else { continue }
                total += 1
                let sample = MKMapPoint(x: center.x + dx, y: center.y + dy).coordinate
                let candidate = GeoCoordinate(latitude: sample.latitude, longitude: sample.longitude)
                if !isExplored(candidate) { unknown += 1 }
            }
        }
        return total == 0 ? 0 : Double(unknown) / Double(total)
    }

    private func sampledRoute(_ coordinates: [GeoCoordinate], spacingMeters: Double) -> [GeoCoordinate] {
        guard let first = coordinates.first else { return [] }
        var result = [first]
        let spacingMapPoints = max(1, spacingMeters * mapPointsPerMeter)
        for pair in zip(coordinates, coordinates.dropFirst()) {
            let source = MKMapPoint(pair.0.clCoordinate)
            let destination = MKMapPoint(pair.1.clCoordinate)
            let distance = hypot(destination.x - source.x, destination.y - source.y)
            let count = max(1, Int(ceil(distance / spacingMapPoints)))
            for step in 1...count {
                let progress = Double(step) / Double(count)
                let sample = MKMapPoint(
                    x: source.x + (destination.x - source.x) * progress,
                    y: source.y + (destination.y - source.y) * progress
                ).coordinate
                result.append(GeoCoordinate(latitude: sample.latitude, longitude: sample.longitude))
            }
        }
        return result
    }

    private func cell(for mapPoint: MKMapPoint) -> Cell {
        Cell(
            x: Int32(floor(mapPoint.x / cellSizeMapPoints)),
            y: Int32(floor(mapPoint.y / cellSizeMapPoints))
        )
    }

    private static func fillCells(
        around mapPoint: MKMapPoint,
        radiusMeters: Double,
        cellSizeMapPoints: Double,
        mapPointsPerMeter: Double,
        into cells: inout Set<Cell>
    ) {
        let centerX = Int32(floor(mapPoint.x / cellSizeMapPoints))
        let centerY = Int32(floor(mapPoint.y / cellSizeMapPoints))
        let radiusMapPoints = max(0, radiusMeters * mapPointsPerMeter)
        let cellRadius = Int32(ceil(radiusMapPoints / cellSizeMapPoints))
        for x in (centerX - cellRadius)...(centerX + cellRadius) {
            for y in (centerY - cellRadius)...(centerY + cellRadius) {
                let cellCenter = MKMapPoint(
                    x: (Double(x) + 0.5) * cellSizeMapPoints,
                    y: (Double(y) + 0.5) * cellSizeMapPoints
                )
                if hypot(cellCenter.x - mapPoint.x, cellCenter.y - mapPoint.y)
                    <= radiusMapPoints + cellSizeMapPoints * 0.72 {
                    cells.insert(Cell(x: x, y: y))
                }
            }
        }
    }
}
