import Foundation

/// Imported GPS/GPX coordinates are WGS-84. Apple map tiles in mainland China
/// use the legally required encrypted offset, so imported geometry must be
/// transformed only at the map boundary. The stored/exported source remains
/// untouched and locations outside mainland China pass through unchanged.
enum ChinaCoordinateTransform {
    static func mapCoordinate(for coordinate: GeoCoordinate) -> GeoCoordinate {
        guard isInsideMainlandChina(coordinate) else { return coordinate }

        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        var latitudeDelta = transformLatitude(longitude - 105, latitude - 35)
        var longitudeDelta = transformLongitude(longitude - 105, latitude - 35)
        let radianLatitude = latitude / 180 * .pi
        var magic = sin(radianLatitude)
        magic = 1 - 0.006693421622965943 * magic * magic
        let squareRootMagic = sqrt(magic)
        latitudeDelta = latitudeDelta * 180
            / ((6_378_245 * (1 - 0.006693421622965943)) / (magic * squareRootMagic) * .pi)
        longitudeDelta = longitudeDelta * 180
            / (6_378_245 / squareRootMagic * cos(radianLatitude) * .pi)

        return GeoCoordinate(
            latitude: latitude + latitudeDelta,
            longitude: longitude + longitudeDelta
        )
    }

    private static func isInsideMainlandChina(_ coordinate: GeoCoordinate) -> Bool {
        (72.004...137.8347).contains(coordinate.longitude)
            && (0.8293...55.8271).contains(coordinate.latitude)
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y
            + 0.2 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        result += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y
            + 0.1 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        result += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return result
    }
}
