import Foundation
import MapKit
import UIKit

enum NavigationApp: String, CaseIterable, Identifiable {
    case amap, apple
    var id: Self { self }
    var title: String { self == .amap ? "高德地图" : "Apple 地图" }
}

enum ExternalNavigationError: LocalizedError {
    case invalidCoordinate, amapUnavailable, launchFailed(NavigationApp)
    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: "目的地坐标无效，请重新选择地点。"
        case .amapUnavailable: "未检测到高德地图，请安装后重试，或切换到 Apple 地图。"
        case .launchFailed(let app): "无法打开\(app.title)，请确认已安装后重试，或切换其他地图。"
        }
    }
}

enum ExternalNavigation {
    /// Recommendations and long-press destinations already use map coordinates (GCJ-02
    /// in mainland China). Do NOT transform them again or pass Apple's POI IDs to AMap.
    static func amapURL(coordinate: GeoCoordinate, name: String, travelMode: ExploreTravelMode) throws -> URL {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else {
            throw ExternalNavigationError.invalidCoordinate
        }
        let transport: String
        switch travelMode {
        case .walking: transport = "2"
        case .cycling: transport = "3"
        case .automobile: transport = "0"
        }
        var components = URLComponents()
        components.scheme = "iosamap"
        components.host = "path"
        components.queryItems = [
            URLQueryItem(name: "sourceApplication", value: "迷雾足迹"),
            URLQueryItem(name: "dlat", value: String(coordinate.latitude)),
            URLQueryItem(name: "dlon", value: String(coordinate.longitude)),
            URLQueryItem(name: "dname", value: name),
            URLQueryItem(name: "dev", value: "0"),
            URLQueryItem(name: "t", value: transport)
        ]
        // Some third-party query parsers interpret a literal '+' as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        // Omit the origin so the navigation app uses its own fresh current location.
        guard let url = components.url else { throw ExternalNavigationError.invalidCoordinate }
        return url
    }

    @MainActor
    static func open(_ recommendation: ExploreRecommendation, in app: NavigationApp,
                     travelMode: ExploreTravelMode) async throws {
        switch app {
        case .amap:
            let url = try amapURL(coordinate: recommendation.coordinate, name: recommendation.title, travelMode: travelMode)
            guard UIApplication.shared.canOpenURL(url) else { throw ExternalNavigationError.amapUnavailable }
            guard await UIApplication.shared.open(url, options: [:]) else { throw ExternalNavigationError.launchFailed(.amap) }
        case .apple:
            let item = recommendation.mapItem ?? MKMapItem(location: recommendation.coordinate.location, address: nil)
            if item.name == nil { item.name = recommendation.title }
            let mode: String
            switch travelMode {
            case .walking: mode = MKLaunchOptionsDirectionsModeWalking
            case .cycling: mode = MKLaunchOptionsDirectionsModeCycling
            case .automobile: mode = MKLaunchOptionsDirectionsModeDriving
            }
            guard item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode]) else {
                throw ExternalNavigationError.launchFailed(.apple)
            }
        }
    }
}
