import Foundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

/// GCP (primary): Firestore realtime listener + Cloud Storage + Cloud Functions.
@MainActor
final class FirebaseBackend: MealBackend {
    let kind = BackendKind.gcp
    private let uid: String
    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let functions = Functions.functions(region: "asia-northeast1")
    private var listener: ListenerRegistration?

    init(uid: String) { self.uid = uid }

    func start(onChange: @escaping ([Meal]) -> Void, onError: @escaping (String) -> Void) {
        listener?.remove()
        listener = db.collection("users/\(uid)/meals")
            .order(by: "takenAt", descending: true)
            .addSnapshotListener { snap, err in
                Task { @MainActor in
                    if let err { onError(err.localizedDescription); return }
                    onChange(snap?.documents.map { Meal(id: $0.documentID, data: $0.data()) } ?? [])
                }
            }
    }

    func stop() { listener?.remove(); listener = nil }

    func refresh() async {}

    func add(jpeg: Data, takenAt: Date?, lat: Double?, lng: Double?, placeName: String) async throws -> String {
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
        return ref.documentID
    }

    func analyze(mealId: String) async throws {
        _ = try await functions.httpsCallable("analyzeDish").call(["mealId": mealId])
    }

    func update(_ meal: Meal) async throws {
        try await db.document("users/\(uid)/meals/\(meal.id)").updateData([
            "photoPath": meal.photoPath,
            "dish": meal.dish, "genre": meal.genre,
            "placeName": meal.placeName, "memo": meal.memo,
        ])
    }

    func delete(_ meal: Meal) async throws {
        try? await storage.reference(withPath: meal.photoPath).delete()
        try await db.document("users/\(uid)/meals/\(meal.id)").delete()
    }

    func imageData(path: String) async -> Data? {
        guard !path.isEmpty else { return nil }
        return try? await storage.reference(withPath: path).data(maxSize: 10 * 1024 * 1024)
    }

    /// Owner-only: copy every meal + photo to AWS (initial backfill for the BCP copy).
    func backfillToAWS() async throws -> String {
        let r = try await functions.httpsCallable("backfillMealsToAws").call()
        let d = r.data as? [String: Any] ?? [:]
        return "全\(d["total"] ?? "?")件 / 成功\(d["ok"] ?? "?") / 失敗\(d["failed"] ?? "?")"
    }
}
