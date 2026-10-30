import Foundation
import UIKit

@MainActor
final class MealStore: ObservableObject {
    @Published var meals: [Meal] = []
    @Published var errorMessage: String?
    @Published var bulkRunning = false
    @Published private(set) var kind: BackendKind = .gcp

    private(set) var backend: MealBackend?
    private var key: String?

    /// GCP (Firebase) mode
    func start(uid: String) { activate(FirebaseBackend(uid: uid), key: "gcp:\(uid)") }

    /// AWS (BCP) mode
    func startAWS(auth: AWSAuth) {
        guard let b = AWSBackend(auth: auth) else { errorMessage = "AWSConfig.plist がありません"; return }
        activate(b, key: "aws")
    }

    private func activate(_ b: MealBackend, key: String) {
        guard self.key != key else { return }
        stop()
        self.key = key
        backend = b
        kind = b.kind
        ImageCache.shared.removeAll()
        ImageCache.shared.loader = { [weak b] path in await b?.imageData(path: path) }
        b.start(onChange: { [weak self] in self?.meals = $0 },
                onError: { [weak self] in self?.errorMessage = $0 })
    }

    func stop() {
        backend?.stop(); backend = nil; key = nil; meals = []
        ImageCache.shared.removeAll()
    }

    func refresh() async { await backend?.refresh() }

    func add(jpeg: Data, takenAt: Date?, lat: Double?, lng: Double?, placeName: String) async throws -> String {
        guard let backend else { throw BackendError(message: "未ログイン") }
        let id = try await backend.add(jpeg: jpeg, takenAt: takenAt, lat: lat, lng: lng, placeName: placeName)
        Task { await analyze(mealId: id) }
        return id
    }

    func analyze(mealId: String) async {
        do { try await backend?.analyze(mealId: mealId) }
        catch { errorMessage = "AI分析に失敗: \(error.localizedDescription)" }
    }

    /// Re-run AI for every meal that is not analyzed yet (pending / error).
    func analyzeAllFailed() async {
        bulkRunning = true
        defer { bulkRunning = false }
        for m in meals where m.needsAI { await analyze(mealId: m.id) }
    }

    func update(_ meal: Meal) async throws { try await backend?.update(meal) }

    func delete(_ meal: Meal) async throws {
        try await backend?.delete(meal)
        ImageCache.shared.remove(meal.photoPath)
    }
}

/// In-memory cache of downloaded photos. Loader is swapped with the active backend.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    var loader: ((String) async -> Data?)?

    func remove(_ path: String) { cache.removeObject(forKey: path as NSString) }
    func removeAll() { cache.removeAllObjects() }

    func image(path: String) async -> UIImage? {
        if let img = cache.object(forKey: path as NSString) { return img }
        guard !path.isEmpty, let data = await loader?(path), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
