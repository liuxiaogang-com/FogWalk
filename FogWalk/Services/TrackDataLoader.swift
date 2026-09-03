import Foundation

enum TrackDataError: LocalizedError {
    case missingResource(String)
    case malformedCSV(String)
    case malformedGPX
    case unsupportedFile(String)
    case noUsablePoints

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "找不到数据文件：\(name)"
        case .malformedCSV(let name):
            return "CSV 格式无法解析：\(name)"
        case .malformedGPX:
            return "GPX 格式无法解析"
        case .unsupportedFile(let name):
            return "不支持这个文件：\(name)"
        case .noUsablePoints:
            return "所选文件中没有找到可用的位置数据。"
        }
    }
}

struct TrackDataLoader: Sendable {
    struct InputURLs: Sendable {
        let recordedCSV: URL
        let photoCSV: URL
        let gpx: URL
    }

    static func bundledInputURLs(bundle: Bundle = .main) throws -> InputURLs {
        guard let recorded = bundle.url(forResource: "backUpData-all", withExtension: "csv") else {
            throw TrackDataError.missingResource("backUpData-all.csv")
        }
        guard let photo = bundle.url(forResource: "backUpPhotoData", withExtension: "csv") else {
            throw TrackDataError.missingResource("backUpPhotoData.csv")
        }
        guard let gpx = bundle.url(forResource: "backUpData-all", withExtension: "gpx") else {
            throw TrackDataError.missingResource("backUpData-all.gpx")
        }
        return InputURLs(recordedCSV: recorded, photoCSV: photo, gpx: gpx)
    }

    static func load(urls: InputURLs) throws -> TrackDataset {
        var nextID: Int64 = 1
        let recordedPoints = try parseCSV(
            at: urls.recordedCSV,
            source: .recordedCSV,
            nextID: &nextID
        )
        let photoPoints = try parseCSV(
            at: urls.photoCSV,
            source: .photoCSV,
            nextID: &nextID
        )
        let gpxPoints = try parseGPX(at: urls.gpx, nextID: &nextID)

        return makeDataset(
            points: recordedPoints + photoPoints + gpxPoints,
            recordedCSVCount: recordedPoints.count,
            photoCSVCount: photoPoints.count,
            gpxCount: gpxPoints.count
        )
    }

    static func importFiles(urls: [URL], existing: TrackDataset?) throws -> TrackDataset {
        var nextID = Int64((existing?.points.count ?? 0) + 1)
        var points = existing?.points ?? []
        var recordedCSVCount = existing?.summary.recordedCSVCount ?? 0
        var photoCSVCount = existing?.summary.photoCSVCount ?? 0
        var gpxCount = existing?.summary.gpxCount ?? 0

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            switch url.pathExtension.lowercased() {
            case "csv":
                let isPhotoFile = url.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveContains("photo")
                let source: TrackSource = isPhotoFile ? .photoCSV : .recordedCSV
                let imported = try parseCSV(at: url, source: source, nextID: &nextID)
                points.append(contentsOf: imported)
                if isPhotoFile {
                    photoCSVCount += imported.count
                } else {
                    recordedCSVCount += imported.count
                }
            case "gpx":
                let imported = try parseGPX(at: url, nextID: &nextID)
                points.append(contentsOf: imported)
                gpxCount += imported.count
            case "fogwalk":
                let imported = try TrackArchiveCodec.decode(Data(contentsOf: url, options: .mappedIfSafe))
                points.append(contentsOf: imported.points)
                recordedCSVCount += imported.summary.recordedCSVCount
                photoCSVCount += imported.summary.photoCSVCount
                gpxCount += imported.summary.gpxCount
            default:
                throw TrackDataError.unsupportedFile(url.lastPathComponent)
            }
        }

        guard !points.isEmpty else { throw TrackDataError.noUsablePoints }
        return makeDataset(
            points: points,
            recordedCSVCount: recordedCSVCount,
            photoCSVCount: photoCSVCount,
            gpxCount: gpxCount
        )
    }

    private static func makeDataset(
        points: [TrackPoint],
        recordedCSVCount: Int,
        photoCSVCount: Int,
        gpxCount: Int
    ) -> TrackDataset {
        var seen = Set<TrackPointKey>(minimumCapacity: points.count)
        var unique = [TrackPoint]()
        unique.reserveCapacity(points.count)

        for point in points where seen.insert(TrackPointKey(point)).inserted {
            unique.append(point)
        }

        unique.sort {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
        unique = unique.enumerated().map { index, point in
            TrackPoint(
                id: Int64(index + 1),
                timestamp: point.timestamp,
                coordinate: point.coordinate,
                horizontalAccuracy: point.horizontalAccuracy,
                speed: point.speed,
                altitude: point.altitude,
                source: point.source
            )
        }
        let rawCount = recordedCSVCount + photoCSVCount + gpxCount

        return TrackDataset(
            points: unique,
            summary: ImportSummary(
                recordedCSVCount: recordedCSVCount,
                photoCSVCount: photoCSVCount,
                gpxCount: gpxCount,
                duplicateCount: max(0, rawCount - unique.count),
                uniqueCount: unique.count,
                earliestDate: unique.first?.timestamp,
                latestDate: unique.last?.timestamp
            )
        )
    }

    static func parseCSV(
        at url: URL,
        source: TrackSource,
        nextID: inout Int64
    ) throws -> [TrackPoint] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(whereSeparator: \.isNewline).makeIterator()
        guard let headerLine = lines.next() else {
            throw TrackDataError.malformedCSV(url.lastPathComponent)
        }

        let headers = headerLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        guard let timeIndex = index["dataTime"],
              let longitudeIndex = index["longitude"],
              let latitudeIndex = index["latitude"] else {
            throw TrackDataError.malformedCSV(url.lastPathComponent)
        }

        let accuracyIndex = index["accuracy"]
        let speedIndex = index["speed"]
        let altitudeIndex = index["altitude"]
        var points = [TrackPoint]()
        points.reserveCapacity(source == .photoCSV ? 4_000 : 160_000)

        while let line = lines.next() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(timeIndex, longitudeIndex, latitudeIndex),
                  let timestamp = TimeInterval(fields[timeIndex]),
                  let longitude = Double(fields[longitudeIndex]),
                  let latitude = Double(fields[latitudeIndex]),
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude),
                  latitude != 0,
                  longitude != 0 else {
                continue
            }

            let accuracy = accuracyIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil } ?? 0
            let speed = speedIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil } ?? -1
            let altitude = altitudeIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil } ?? 0
            points.append(
                TrackPoint(
                    id: nextID,
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                    horizontalAccuracy: accuracy,
                    speed: speed,
                    altitude: altitude,
                    source: source
                )
            )
            nextID += 1
        }
        return points
    }

    static func parseGPX(at url: URL, nextID: inout Int64) throws -> [TrackPoint] {
        let parser = XMLParser(contentsOf: url)
        let delegate = GPXParserDelegate(firstID: nextID)
        parser?.delegate = delegate
        guard parser?.parse() == true else {
            throw parser?.parserError ?? TrackDataError.malformedGPX
        }
        nextID += Int64(delegate.points.count)
        return delegate.points
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private let isoFormatter = ISO8601DateFormatter()
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double = 0
    private var currentSpeed: Double = -1
    private var currentTime: Date?
    private var currentElement = ""
    private var elementText = ""
    private var nextID: Int64

    private(set) var points: [TrackPoint] = []

    init(firstID: Int64) {
        nextID = firstID
        points.reserveCapacity(160_000)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        elementText = ""
        if elementName == "trkpt" {
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentElevation = 0
            currentSpeed = -1
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elementText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "ele":
            currentElevation = Double(value) ?? 0
        case "speed":
            currentSpeed = Double(value) ?? -1
        case "time":
            currentTime = isoFormatter.date(from: value)
        case "trkpt":
            if let latitude = currentLatitude,
               let longitude = currentLongitude,
               let timestamp = currentTime {
                points.append(
                    TrackPoint(
                        id: nextID,
                        timestamp: timestamp,
                        coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                        horizontalAccuracy: 0,
                        speed: currentSpeed,
                        altitude: currentElevation,
                        source: .gpx
                    )
                )
                nextID += 1
            }
            currentLatitude = nil
            currentLongitude = nil
            currentTime = nil
        default:
            break
        }
        currentElement = ""
        elementText = ""
    }
}
