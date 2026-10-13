import Foundation
import UIKit
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

@MainActor
final class MealStore: ObservableObject {
    @Published var meals: [Meal] = []
    @Published var errorMessage: String?

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let functions = Functions.functions(region: "asia-northeast1")
    private var listener: ListenerRegistration?
    private(set) var uid: String?

    func start(uid: String) {
        guard self.uid != uid else { return }
        stop()
        self.uid = uid
        listener = db.collection("users/\(uid)/meals")
            .order(by: "takenAt", descending: true)
            .addSnapshotListener { [weak self] snap, err in
                Task { @MainActor in
                    if let err { self?.errorMessage = err.localizedDescription; return }
                    self?.meals = snap?.documents.map { Meal(id: $0.documentID, data: $0.data()) } ?? []
                }
            }
    }

    func stop() {
        listener?.remove(); listener = nil; uid = nil; meals = []
    }

    /// Uploads a stripped JPEG, creates the Firestore doc, then asks the function to analyze it.
    func add(jpeg: Data, takenAt: Date?, lat: Double?, lng: Double?, placeName: String) async throws -> String {
        guard let uid else { throw NSError(domain: "KithFood", code: 1, userInfo: [NSLocalizedDescriptionKey: "未ログイン"]) }
        let ref = db.collection("users/\(uid)/meals").document()
        let path = "users/\(uid)/meals/\(ref.documentID).jpg"
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await storage.reference(withPath: path).putDataAsync(jpeg, metadata: meta)
        var data: [String: Any] = [
            "photoPath": path,
            "takenAt": Timestamp(date: takenAt ?? Date()),
            "placeName": placeName,
            "dish": "", "genre": "", "memo": "",
            "aiStatus": "pending",
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let lat, let lng {
            data["lat"] = lat; data["lng"] = lng
            data["geohash"] = Geohash.encode(lat: lat, lng: lng)
        }
        try await ref.setData(data)
        Task { await analyze(mealId: ref.documentID) }
        return ref.documentID
    }

    func analyze(mealId: String) async {
        do {
            _ = try await functions.httpsCallable("analyzeDish").call(["mealId": mealId])
        } catch {
            errorMessage = "AI分析に失敗: \(error.localizedDescription)"
        }
    }

    func update(_ meal: Meal) async throws {
        guard let uid else { return }
        try await db.document("users/\(uid)/meals/\(meal.id)").updateData([
            "photoPath": meal.photoPath,
            "dish": meal.dish, "genre": meal.genre,
            "placeName": meal.placeName, "memo": meal.memo,
        ])
    }

    func delete(_ meal: Meal) async throws {
        guard let uid else { return }
        try? await storage.reference(withPath: meal.photoPath).delete()
        ImageCache.shared.remove(meal.photoPath)
        try await db.document("users/\(uid)/meals/\(meal.id)").delete()
    }
}

/// In-memory cache of downloaded photos.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    func remove(_ path: String) { cache.removeObject(forKey: path as NSString) }

    func image(path: String) async -> UIImage? {
        if let img = cache.object(forKey: path as NSString) { return img }
        guard !path.isEmpty,
              let data = try? await Storage.storage().reference(withPath: path).data(maxSize: 10 * 1024 * 1024),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
