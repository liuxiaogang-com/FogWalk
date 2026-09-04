import Foundation
import MapKit

@main
struct MapKitProbe {
    static func main() async {
        let start = CLLocation(latitude: 34.73886358890554, longitude: 113.70164610951689)
        let region = MKCoordinateRegion(
            center: start.coordinate,
            latitudinalMeters: 7_000,
            longitudinalMeters: 7_000
        )
        let request = MKLocalSearch.Request(naturalLanguageQuery: "公园", region: region)
        request.resultTypes = .pointOfInterest

        do {
            let response = try await MKLocalSearch(request: request).start()
            print("SEARCH_OK count=\(response.mapItems.count)")
            for item in response.mapItems.prefix(8) {
                let routeRequest = MKDirections.Request()
                routeRequest.source = MKMapItem(location: start, address: nil)
                routeRequest.destination = item
                routeRequest.transportType = .walking
                do {
                    let routes = try await MKDirections(request: routeRequest).calculate().routes
                    if let route = routes.first {
                        print("ROUTE_OK \(item.name ?? "unnamed") minutes=\(Int(route.expectedTravelTime / 60)) meters=\(Int(route.distance))")
                    }
                } catch {
                    let nsError = error as NSError
                    print("ROUTE_FAIL \(item.name ?? "unnamed") domain=\(nsError.domain) code=\(nsError.code)")
                }
            }
        } catch {
            let nsError = error as NSError
            print("SEARCH_FAIL domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)")
        }
    }
}
