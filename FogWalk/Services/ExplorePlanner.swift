import Foundation
import MapKit

enum ExplorePlannerError: LocalizedError {
    case loopTemporarilyUnavailable
    case placeSearchUnavailable
    case noNamedDestination

    var errorDescription: String? {
        switch self {
        case .loopTemporarilyUnavailable:
            return "真实闭环路线仍在开发中，请先使用目的地探索。"
        case .placeSearchUnavailable:
            return "Apple 地图地点服务暂时没有响应，请稍后再试。"
        case .noNamedDestination:
            return "这个时间范围内没有找到合适的明确终点，请增加时间或更换地点类型。"
        }
    }
}

@MainActor
struct ExplorePlanner {
    private struct ScoredRecommendation {
        let recommendation: ExploreRecommendation
        let score: Double
    }

    func recommendations(
        start: GeoCoordinate,
        mode: ExploreMode,
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        explorationGrid: ExplorationGrid
    ) async throws -> [ExploreRecommendation] {
        guard mode == .destination else {
            throw ExplorePlannerError.loopTemporarilyUnavailable
        }
        return try await destinationRecommendations(
            start: start,
            minutes: minutes,
            travelMode: travelMode,
            category: category,
            explorationGrid: explorationGrid
        )
    }

    private func destinationRecommendations(
        start: GeoCoordinate,
        minutes: Int,
        travelMode: ExploreTravelMode,
        category: ExploreCategory,
        explorationGrid: ExplorationGrid
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
                    && $0.distance <= radius
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
        for candidate in preselected.prefix(12) {
            if let verified = try? await routeRecommendation(
                start: start,
                mapItem: candidate.item,
                requestedMinutes: minutes,
                travelMode: travelMode,
                explorationGrid: explorationGrid,
                destinationNovelty: candidate.destinationNovelty,
                placePriority: candidate.placePriority
            ) {
                verifiedRecommendations.append(verified)
            }
        }
        if !verifiedRecommendations.isEmpty {
            return verifiedRecommendations
                .sorted { $0.score > $1.score }
                .prefix(6)
                .map(\.recommendation)
        }

        // A named endpoint remains useful even when MKDirections has no walking
        // graph for it. Mark the time as an estimate and let Maps retry from the
        // device's live position instead of surfacing raw MKError code 5.
        return Array(preselected.prefix(6).map { candidate in
            let item = candidate.item
            let coordinate = GeoCoordinate(
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude
            )
            return ExploreRecommendation(
                title: item.name ?? category.rawValue,
                subtitle: "明确终点 · 路线将在 Apple 地图中再次确认",
                coordinate: coordinate,
                estimatedMinutes: max(
                    1,
                    Int((candidate.distance / travelMode.estimatedMetersPerSecond / 60).rounded())
                ),
                distanceMeters: candidate.distance,
                routeCoordinates: [],
                routeNoveltyRatio: 0,
                destinationNoveltyRatio: candidate.destinationNovelty,
                mapItem: item,
                isRouteVerified: false
            )
        })
    }

    private func searchMapItems(
        category: ExploreCategory,
        region: MKCoordinateRegion
    ) async throws -> [MKMapItem] {
        var items = [MKMapItem]()
        var receivedResponse = false

        let pointsRequest = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        pointsRequest.pointOfInterestFilter = MKPointOfInterestFilter(
            including: category.pointOfInterestCategories
        )
        if let response = try? await MKLocalSearch(request: pointsRequest).start() {
            receivedResponse = true
            items.append(contentsOf: response.mapItems)
        }

        // Always supplement the structured request. In mainland China it can
        // return many nearby generic POIs while omitting familiar chains or
        // clearly named restaurants that are slightly farther into the fog.
        for query in category.searchQueries {
            let request = MKLocalSearch.Request(
                naturalLanguageQuery: query,
                region: region
            )
            request.resultTypes = .pointOfInterest
            if let response = try? await MKLocalSearch(request: request).start() {
                receivedResponse = true
                items.append(contentsOf: response.mapItems)
            }
        }

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
        placePriority: Double
    ) async throws -> ScoredRecommendation {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: start.location, address: nil)
        request.destination = mapItem
        request.transportType = travelMode.mapKitType
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else {
            throw MKError(.directionsNotFound)
        }

        let scoredRoutes = response.routes.map { route -> (MKRoute, [GeoCoordinate], Double, Double) in
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
        let budgetDifference = abs(etaMinutes - requestedMinutes)
        let budgetNote = budgetDifference <= max(5, requestedMinutes / 3)
            ? "符合时间预算"
            : "时间略有偏差"

        return ScoredRecommendation(
            recommendation: ExploreRecommendation(
                title: mapItem.name ?? "探索目的地",
                subtitle: "\(budgetNote) · 优先穿过未知区域",
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
}
