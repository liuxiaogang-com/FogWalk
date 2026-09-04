import Foundation
import MapKit

@MainActor
private final class MapServiceCancellation {
    var directions: MKDirections?
    var search: MKLocalSearch?
    func cancel() { directions?.cancel(); search?.cancel() }
}

enum ExplorePlannerError: LocalizedError {
    case routeServiceUnavailable
    case placeSearchUnavailable
    case noNamedDestination
    case noRouteWithinBudget

    var errorDescription: String? {
        switch self {
        case .routeServiceUnavailable:
            return "已找到未探索地点，但暂时无法验证可通行路线。请稍后重试或更换出行方式，不会以直线估算替代道路。"
        case .placeSearchUnavailable:
            return "Apple 地图地点服务暂时没有响应，请稍后再试。"
        case .noNamedDestination:
            return "附近暂未找到未探索的这类地点。可以更换类型，或主动增加时间。"
        case .noRouteWithinBudget:
            return "找到了目的地，但可用路线超过单程时间预算。请增加时间后重试。"
        }
    }
}

@MainActor
struct ExplorePlanner {
    static func fitsBudget(seconds: Double, minutes: Int) -> Bool {
        seconds.isFinite && seconds >= 0 && minutes > 0 && seconds <= Double(minutes * 60)
    }
    private struct ScoredRecommendation {
        let recommendation: ExploreRecommendation
        let score: Double
    }

    func recommendations(
        start: GeoCoordinate,
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        explorationGrid: ExplorationGrid,
        excluding: Set<String> = []
    ) async throws -> [ExploreRecommendation] {
        return try await destinationRecommendations(
            start: start,
            minutes: minutes,
            travelMode: travelMode,
            category: category,
            explorationGrid: explorationGrid,
            excluding: excluding
        )
    }

    private func destinationRecommendations(
        start: GeoCoordinate,
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        explorationGrid: ExplorationGrid,
        excluding: Set<String>
    ) async throws -> [ExploreRecommendation] {
        let targetDistance = travelMode.estimatedMetersPerSecond * Double(minutes * 60)
        let radius = min(max(targetDistance * 1.5, 1_200), 50_000)
        let region = MKCoordinateRegion(
            center: start.clCoordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        let mapItems = try await searchMapItems(category: category, region: region)

        let eligible = mapItems
            .compactMap { item -> (item: MKMapItem, distance: Double, destinationNovelty: Double, placePriority: Double, score: Double)? in
                guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                let coordinate = GeoCoordinate(
                    latitude: item.location.coordinate.latitude,
                    longitude: item.location.coordinate.longitude
                )
                // This is a hard eligibility rule, not merely a ranking hint:
                // an endpoint inside the 50 m explored raster can never be recommended.
                guard !explorationGrid.isExplored(coordinate) else { return nil }
                let distance = start.location.distance(from: coordinate.location)
                let destinationNovelty = explorationGrid.noveltyRatio(around: coordinate)
                let distanceFitness = max(
                    0,
                    1 - abs(distance - targetDistance * 0.78) / max(targetDistance, 1)
                )
                let placePriority = category.placePriority(name: name)
                return (
                    item,
                    distance,
                    destinationNovelty,
                    placePriority,
                    destinationNovelty * 0.55 + distanceFitness * 0.25 + placePriority * 0.20
                )
            }
            .filter {
                $0.distance >= targetDistance * 0.12
                    && $0.distance <= targetDistance
            }

        // The endpoint itself must always be outside the explored 50 m raster.
        // Prefer a broadly unknown neighborhood, but do not discard every named
        // restaurant/cafe merely because one edge of its surroundings was visited.
        let preferred = eligible.filter { $0.destinationNovelty >= 0.50 }
        let acceptable = eligible.filter { $0.destinationNovelty >= 0.30 }
        let preselected = (!preferred.isEmpty
            ? preferred
            : (!acceptable.isEmpty ? acceptable : eligible))
            .sorted { $0.score > $1.score }

        guard !preselected.isEmpty else { throw ExplorePlannerError.noNamedDestination }

        var verifiedRecommendations = [ScoredRecommendation]()
        var unresolvedItems = Set<String>()
        var overBudgetCount = 0
        let routeCandidates = preselected.sorted {
            let left = excluding.contains(Self.destinationKey($0.item))
            let right = excluding.contains(Self.destinationKey($1.item))
            return left == right ? $0.score > $1.score : !left
        }
        for candidate in routeCandidates.prefix(12) {
            try Task.checkCancellation()
            do {
                let verified = try await routeRecommendation(
                start: start,
                mapItem: candidate.item,
                requestedMinutes: minutes,
                travelMode: travelMode,
                explorationGrid: explorationGrid,
                destinationNovelty: candidate.destinationNovelty,
                placePriority: candidate.placePriority
                )
                verifiedRecommendations.append(verified)
            } catch ExplorePlannerError.noRouteWithinBudget {
                overBudgetCount += 1
            } catch {
                try Task.checkCancellation()
                unresolvedItems.insert(Self.destinationKey(candidate.item))
            }
        }
        return try Self.validatedResults(verifiedRecommendations.sorted { $0.score > $1.score }.map(\.recommendation),
            unresolvedCount: unresolvedItems.count, overBudgetCount: overBudgetCount, excluding: excluding)
    }

    static func validatedResults(_ ranked: [ExploreRecommendation], unresolvedCount: Int,
                                 overBudgetCount: Int, excluding: Set<String>) throws -> [ExploreRecommendation] {
        let verified = ranked.filter { $0.isRouteVerified && $0.routeCoordinates.count >= 2 }
        if !verified.isEmpty { return diverseResults(verified, excluding: excluding) }
        if unresolvedCount == 0, overBudgetCount > 0 { throw ExplorePlannerError.noRouteWithinBudget }
        throw ExplorePlannerError.routeServiceUnavailable
    }

    static func diverseResults(_ ranked: [ExploreRecommendation], excluding: Set<String>) -> [ExploreRecommendation] {
        let fresh = ranked.filter { !excluding.contains($0.stableKey) }
        let pool = fresh.isEmpty ? ranked : fresh
        var selected = [ExploreRecommendation]()
        for candidate in pool {
            let baseName = candidate.title.components(separatedBy: CharacterSet(charactersIn: "(（")).first ?? candidate.title
            guard !selected.contains(where: {
                $0.coordinate.location.distance(from: candidate.coordinate.location) < 120
                    || $0.title.components(separatedBy: CharacterSet(charactersIn: "(（")).first == baseName
            }) else { continue }
            selected.append(candidate)
            if selected.count == 6 { return selected }
        }
        for candidate in pool where !selected.contains(where: { $0.stableKey == candidate.stableKey }) {
            selected.append(candidate)
            if selected.count == 6 { break }
        }
        return selected
    }

    private static func destinationKey(_ item: MKMapItem) -> String {
        "\((item.name ?? "").lowercased())|\(Int((item.location.coordinate.latitude * 10_000).rounded()))|\(Int((item.location.coordinate.longitude * 10_000).rounded()))"
    }

    func previewRoute(start: GeoCoordinate, destination: MKMapItem, travelMode: ExploreTravelMode,
                      explorationGrid: ExplorationGrid) async throws -> ExploreRecommendation {
        let coordinate = GeoCoordinate(latitude: destination.location.coordinate.latitude,
                                       longitude: destination.location.coordinate.longitude)
        return try await routeRecommendation(start: start, mapItem: destination, requestedMinutes: 30,
            travelMode: travelMode, explorationGrid: explorationGrid,
            destinationNovelty: explorationGrid.noveltyRatio(around: coordinate), placePriority: 0,
            enforceBudget: false).recommendation
    }

    private func searchMapItems(
        category: ExploreCategory,
        region: MKCoordinateRegion
    ) async throws -> [MKMapItem] {
        var items = [MKMapItem]()
        var receivedResponse = false
        try Task.checkCancellation()

        let pointsRequest = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        pointsRequest.pointOfInterestFilter = MKPointOfInterestFilter(
            including: category.pointOfInterestCategories
        )
        if let response = try? await runSearch(MKLocalSearch(request: pointsRequest)) {
            receivedResponse = true
            items.append(contentsOf: response.mapItems)
        }

        // Always supplement the structured request. In mainland China it can
        // return many nearby generic POIs while omitting familiar chains or
        // clearly named restaurants that are slightly farther into the fog.
        for query in category.searchQueries {
            try Task.checkCancellation()
            let request = MKLocalSearch.Request(
                naturalLanguageQuery: query,
                region: region
            )
            request.resultTypes = .pointOfInterest
            if let response = try? await runSearch(MKLocalSearch(request: request)) {
                receivedResponse = true
                items.append(contentsOf: response.mapItems)
            }
        }

        try Task.checkCancellation()

        guard receivedResponse else { throw ExplorePlannerError.placeSearchUnavailable }

        var seen = Set<String>()
        return items.filter { item in
            let coordinate = item.location.coordinate
            let key = "\(item.name ?? "")|\((coordinate.latitude * 100_000).rounded())|\((coordinate.longitude * 100_000).rounded())"
            return seen.insert(key).inserted
        }
    }

    private func routeRecommendation(
        start: GeoCoordinate,
        mapItem: MKMapItem,
        requestedMinutes: Int,
        travelMode: ExploreTravelMode,
        explorationGrid: ExplorationGrid,
        destinationNovelty: Double,
        placePriority: Double,
        enforceBudget: Bool = true
    ) async throws -> ScoredRecommendation {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: start.location, address: nil)
        request.destination = mapItem
        request.transportType = travelMode.mapKitType
        request.requestsAlternateRoutes = true
        let directions = MKDirections(request: request)
        let cancellation = MapServiceCancellation()
        cancellation.directions = directions
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
        try Task.checkCancellation()
        guard !response.routes.isEmpty else {
            throw MKError(.directionsNotFound)
        }

        let usableRoutes = response.routes.filter { !enforceBudget || Self.fitsBudget(seconds: $0.expectedTravelTime, minutes: requestedMinutes) }
        guard !usableRoutes.isEmpty else { throw ExplorePlannerError.noRouteWithinBudget }
        let scoredRoutes = usableRoutes.map { route -> (MKRoute, [GeoCoordinate], Double, Double) in
            var coordinates = Array(
                repeating: CLLocationCoordinate2D(),
                count: route.polyline.pointCount
            )
            route.polyline.getCoordinates(
                &coordinates,
                range: NSRange(location: 0, length: route.polyline.pointCount)
            )
            let geoCoordinates = coordinates.map {
                GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            let routeNovelty = explorationGrid.noveltyRatio(along: geoCoordinates)
            let timeFitness = max(
                0,
                1 - abs(route.expectedTravelTime / 60 - Double(requestedMinutes))
                    / Double(max(requestedMinutes, 1))
            )
            let score = routeNovelty * 0.48
                + destinationNovelty * 0.27
                + timeFitness * 0.15
                + placePriority * 0.10
            return (route, geoCoordinates, routeNovelty, score)
        }
        guard let best = scoredRoutes.max(by: { $0.3 < $1.3 }) else {
            throw MKError(.directionsNotFound)
        }
        let route = best.0
        let geoCoordinates = best.1
        let novelty = best.2
        let etaMinutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        let coordinate = GeoCoordinate(
            latitude: mapItem.location.coordinate.latitude,
            longitude: mapItem.location.coordinate.longitude
        )

        return ScoredRecommendation(
            recommendation: ExploreRecommendation(
                title: mapItem.name ?? "探索目的地",
                subtitle: enforceBudget ? "单程预算内 · 优先穿过未知区域" : "路线预览 · 自选目的地",
                coordinate: coordinate,
                estimatedMinutes: etaMinutes,
                distanceMeters: route.distance,
                routeCoordinates: geoCoordinates,
                routeNoveltyRatio: novelty,
                destinationNoveltyRatio: destinationNovelty,
                mapItem: mapItem,
                isRouteVerified: true
            ),
            score: best.3
        )
    }

    private func runSearch(_ search: MKLocalSearch) async throws -> MKLocalSearch.Response {
        let cancellation = MapServiceCancellation()
        cancellation.search = search
        return try await withTaskCancellationHandler {
            try await search.start()
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
    }
}
