import Foundation
import MapKit

enum ExploreMode: String, CaseIterable, Identifiable {
    case destination = "目的地"
    case loop = "闭环"

    var id: Self { self }
}

enum ExploreTravelMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case walking = "步行"
    case cycling = "骑行"
    case automobile = "驾车"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .automobile: "car.fill"
        }
    }

    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        case .automobile: .automobile
        }
    }

    var estimatedMetersPerSecond: Double {
        switch self {
        case .walking: 1.25
        case .cycling: 4.2
        case .automobile: 10.0
        }
    }
}

enum ExploreCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case any = "任意"
    case cafe = "咖啡厅"
    case tea = "茶饮"
    case park = "公园"
    case library = "图书馆"
    case food = "餐饮"
    case attraction = "景点"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .any: "sparkles"
        case .cafe: "cup.and.saucer.fill"
        case .tea: "mug.fill"
        case .park: "tree.fill"
        case .library: "books.vertical.fill"
        case .food: "fork.knife"
        case .attraction: "camera.fill"
        }
    }

    var pointOfInterestCategories: [MKPointOfInterestCategory] {
        switch self {
        case .any:
            [.cafe, .park, .library, .restaurant, .museum, .landmark]
        case .cafe:
            [.cafe]
        case .tea:
            [.cafe]
        case .park:
            [.park, .nationalPark]
        case .library:
            [.library]
        case .food:
            [.restaurant, .bakery, .foodMarket]
        case .attraction:
            [.museum, .landmark, .nationalMonument]
        }
    }

    var searchQueries: [String] {
        switch self {
        case .any:
            ["公园", "咖啡厅", "图书馆", "博物馆", "景点"]
        case .cafe:
            ["咖啡馆", "瑞幸咖啡", "库迪咖啡", "星巴克"]
        case .tea:
            ["茶饮", "蜜雪冰城", "奶茶", "喜茶"]
        case .park:
            ["公园", "城市公园"]
        case .library:
            ["图书馆", "书店"]
        case .food:
            ["餐厅", "饭店", "快餐", "小吃"]
        case .attraction:
            ["景点", "博物馆"]
        }
    }

    func placePriority(name: String?) -> Double {
        let normalized = (name ?? "").lowercased()
        switch self {
        case .cafe:
            let familiarBrands = ["瑞幸", "luckin", "库迪", "cotti", "星巴克", "starbucks", "蜜雪冰城", "幸运咖", "manner", "挪瓦"]
            if familiarBrands.contains(where: normalized.contains) { return 1 }
            if normalized.contains("咖啡") || normalized.contains("coffee") || normalized.contains("café") {
                return 1
            }
            return 0.42
        case .food:
            let clearFoodWords = ["餐厅", "餐馆", "饭店", "小吃", "面馆", "火锅", "烧烤", "快餐", "食堂", "酒楼", "料理", "麦当劳", "肯德基", "汉堡"]
            return clearFoodWords.contains(where: normalized.contains) ? 0.9 : 0.58
        default:
            return 0.65
        }
    }
}

struct ExploreRecommendation: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: GeoCoordinate
    let estimatedMinutes: Int
    let distanceMeters: Double
    let routeCoordinates: [GeoCoordinate]
    let routeNoveltyRatio: Double
    let destinationNoveltyRatio: Double
    let mapItem: MKMapItem?
    let isRouteVerified: Bool

    var noveltyRatio: Double { routeNoveltyRatio }

    var stableKey: String {
        "\(title.lowercased())|\(Int((coordinate.latitude * 10_000).rounded()))|\(Int((coordinate.longitude * 10_000).rounded()))"
    }

    var timeText: String { "\(isRouteVerified ? "" : "估算约 ")\(estimatedMinutes) 分钟" }
    var distanceText: String {
        let value = distanceMeters >= 1_000
            ? String(format: "%.1f 公里", distanceMeters / 1_000)
            : "\(Int(distanceMeters.rounded())) 米"
        return isRouteVerified ? value : "直线 \(value)"
    }
    var noveltyText: String {
        isRouteVerified
            ? "沿途未探索约 \(Int((routeNoveltyRatio * 100).rounded()))%"
            : "路线待确认"
    }
    var addressText: String {
        mapItem?.address?.shortAddress ?? mapItem?.address?.fullAddress ?? "暂无详细地址"
    }
}

struct ExploreOptions: Codable, Equatable, Sendable {
    var minutes = 30
    var travelMode: ExploreTravelMode = .walking
    var category: ExploreCategory = .any
}

/// Each new search owns a generation. Late callbacks can never publish into a newer one.
struct SearchGeneration {
    private(set) var value = 0
    mutating func advance() -> Int { value &+= 1; return value }
    func accepts(_ generation: Int) -> Bool { generation == value }
}
