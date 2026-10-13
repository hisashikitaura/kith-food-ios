import Foundation
import MapKit

struct PlaceCandidate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let distance: Int
}

enum PlaceSearch {
    /// Nearby restaurants / cafes around the photo location (MapKit, free).
    static func nearby(_ c: CLLocationCoordinate2D, radius: Double = 150) async -> [PlaceCandidate] {
        let req = MKLocalPointsOfInterestRequest(center: c, radius: radius)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket])
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let res = try? await MKLocalSearch(request: req).start() else { return [] }
        return res.mapItems.compactMap { item -> PlaceCandidate? in
            guard let name = item.name else { return nil }
            let d = item.placemark.location.map { Int($0.distance(from: here)) } ?? 0
            return PlaceCandidate(name: name, distance: d)
        }
        .sorted { $0.distance < $1.distance }
    }
}
