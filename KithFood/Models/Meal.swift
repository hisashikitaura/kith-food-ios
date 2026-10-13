import Foundation
import CoreLocation
import FirebaseFirestore

let dishGenres = ["ラーメン", "寿司", "焼肉", "カレー", "中華", "イタリアン",
                  "和食", "洋食", "カフェ・スイーツ", "その他"]

struct Meal: Identifiable, Equatable {
    var id: String
    var photoPath: String
    var takenAt: Date?
    var lat: Double?
    var lng: Double?
    var geohash: String?
    var placeName: String
    var dish: String
    var genre: String
    var memo: String
    var aiStatus: String
    var aiConfidence: Double?
    var aiComment: String
    var createdAt: Date?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    init(id: String, data: [String: Any]) {
        self.id = id
        photoPath = data["photoPath"] as? String ?? ""
        takenAt = (data["takenAt"] as? Timestamp)?.dateValue()
        lat = data["lat"] as? Double
        lng = data["lng"] as? Double
        geohash = data["geohash"] as? String
        placeName = data["placeName"] as? String ?? ""
        dish = data["dish"] as? String ?? ""
        genre = data["genre"] as? String ?? ""
        memo = data["memo"] as? String ?? ""
        aiStatus = data["aiStatus"] as? String ?? "pending"
        aiConfidence = data["aiConfidence"] as? Double
        aiComment = data["aiComment"] as? String ?? ""
        createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
    }

    var displayDish: String { dish.isEmpty ? (aiStatus == "error" ? "未判定" : "分析中…") : dish }
}

/// Minimal geohash encoder (base32), used for future range queries.
enum Geohash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    static func encode(lat: Double, lng: Double, precision: Int = 9) -> String {
        var latR = (-90.0, 90.0), lngR = (-180.0, 180.0)
        var hash = "", bit = 0, ch = 0, even = true
        while hash.count < precision {
            if even {
                let mid = (lngR.0 + lngR.1) / 2
                if lng >= mid { ch |= 1 << (4 - bit); lngR.0 = mid } else { lngR.1 = mid }
            } else {
                let mid = (latR.0 + latR.1) / 2
                if lat >= mid { ch |= 1 << (4 - bit); latR.0 = mid } else { latR.1 = mid }
            }
            even.toggle()
            if bit < 4 { bit += 1 } else { hash.append(base32[ch]); bit = 0; ch = 0 }
        }
        return hash
    }
}
