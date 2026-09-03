#if DEBUG && targetEnvironment(simulator)
import Foundation
import MapKit

/// Synthetic layout-only fixtures. Never included in a device or Release build.
enum UIFixture {
    static var recommendations: [ExploreRecommendation] {
        let start = ChinaCoordinateTransform.mapCoordinate(for: GeoCoordinate(latitude: 31.2304, longitude: 121.4737))
        let names = ["河畔咖啡（示例地点·非真实门店）", "街角书店（界面测试）", "城市花园（界面测试）"]
        return names.enumerated().map { index, name in
            let end = GeoCoordinate(latitude: start.latitude + 0.008 + Double(index) * 0.005,
                                    longitude: start.longitude + 0.006 - Double(index) * 0.007)
            let corner = GeoCoordinate(latitude: start.latitude, longitude: end.longitude)
            let verified = !ProcessInfo.processInfo.arguments.contains("--fixture-unverified")
            let item = MKMapItem(location: end.location, address: nil)
            item.name = name
            return ExploreRecommendation(title: name, subtitle: "合成数据，仅用于界面验收", coordinate: end,
                estimatedMinutes: 18 + index * 4, distanceMeters: 1_200 + Double(index) * 300,
                routeCoordinates: verified ? [start, corner, end] : [], routeNoveltyRatio: 0.76,
                destinationNoveltyRatio: 1, mapItem: item, isRouteVerified: verified)
        }
    }
}
#endif
