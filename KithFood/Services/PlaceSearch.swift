import Foundation
import MapKit

struct PlaceCandidate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let address: String
    let lat: Double
    let lng: Double
    let distance: Int?

    var label: String {
        if let distance { return "\(name)（\(distance)m）" }
        return address.isEmpty ? name : "\(name)・\(address)"
    }

    init(item: MKMapItem, from here: CLLocation?) {
        let c = item.placemark.coordinate
        name = item.name ?? item.placemark.title ?? "名称不明"
        let p = item.placemark
        address = [p.administrativeArea, p.locality, p.thoroughfare, p.subThoroughfare]
            .compactMap { $0 }.joined()
        lat = c.latitude; lng = c.longitude
        distance = here.map { Int(CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: $0)) }
    }
}

enum PlaceSearch {
    /// Nearby restaurants / cafes around the photo location (MapKit, free).
    static func nearby(_ c: CLLocationCoordinate2D, radius: Double = 150) async -> [PlaceCandidate] {
        let req = MKLocalPointsOfInterestRequest(center: c, radius: radius)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket])
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let res = try? await MKLocalSearch(request: req).start() else { return [] }
        return res.mapItems.map { PlaceCandidate(item: $0, from: here) }
            .sorted { ($0.distance ?? 0) < ($1.distance ?? 0) }
    }
}
