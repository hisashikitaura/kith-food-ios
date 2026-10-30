import Foundation
import FirebaseFirestore

/// AWS (BCP): API Gateway + Lambda (Cognito JWT). No realtime; reloads after each change.
/// Writes here are NOT synced back to GCP (one-way GCP -> AWS). See aws/restore-to-gcp.
@MainActor
final class AWSBackend: MealBackend {
    let kind = BackendKind.aws
    private let auth: AWSAuth
    private let cfg: AWSConfig
    private var onChange: (([Meal]) -> Void)?
    private var onError: ((String) -> Void)?
    private var photoURLs: [String: (URL, Date)] = [:]

    init?(auth: AWSAuth) {
        guard let cfg = AWSConfig.shared else { return nil }
        self.auth = auth; self.cfg = cfg
    }

    func start(onChange: @escaping ([Meal]) -> Void, onError: @escaping (String) -> Void) {
        self.onChange = onChange; self.onError = onError
        Task { await refresh() }
    }

    func stop() { onChange = nil; onError = nil }

    func refresh() async {
        do {
            let j = try await call("GET", "/meals")
            let list = (j["meals"] as? [[String: Any]] ?? []).compactMap(Meal.fromJSON)
            onChange?(list.sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) })
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func add(jpeg: Data, takenAt: Date?, lat: Double?, lng: Double?, placeName: String) async throws -> String {
        var body: [String: Any] = ["placeName": placeName,
                                   "takenAt": ISO8601DateFormatter().string(from: takenAt ?? Date())]
        if let lat, let lng { body["lat"] = lat; body["lng"] = lng; body["geohash"] = Geohash.encode(lat: lat, lng: lng) }
        let j = try await call("POST", "/meals", body: body)
        guard let meal = j["meal"] as? [String: Any], let id = meal["id"] as? String,
              let up = (j["uploadUrl"] as? String).flatMap(URL.init(string:)) else {
            throw BackendError(message: "作成に失敗")
        }
        var req = URLRequest(url: up)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: req, from: jpeg)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw BackendError(message: "写真のアップロードに失敗") }
        await refresh()
        return id
    }

    func analyze(mealId: String) async throws {
        defer { Task { await refresh() } }
        _ = try await call("POST", "/meals/\(mealId)/analyze")
    }

    func update(_ meal: Meal) async throws {
        _ = try await call("PATCH", "/meals/\(meal.id)", body: [
            "dish": meal.dish, "genre": meal.genre, "placeName": meal.placeName, "memo": meal.memo,
        ])
        await refresh()
    }

    func delete(_ meal: Meal) async throws {
        _ = try await call("DELETE", "/meals/\(meal.id)")
        await refresh()
    }

    func imageData(path: String) async -> Data? {
        // path = users/<uid>/meals/<id>.jpg; the server resolves uid from the token, we only send the id.
        let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jpg", with: "")
        guard !id.isEmpty else { return nil }
        var url = photoURLs[id].flatMap { $0.1.timeIntervalSinceNow > 30 ? $0.0 : nil }
        if url == nil {
            guard let j = try? await call("GET", "/meals/\(id)/photo"),
                  let u = (j["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            photoURLs[id] = (u, Date().addingTimeInterval(540)); url = u
        }
        guard let url, let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: cfg.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            if code == 401 { auth.signOut() }
            throw BackendError(message: (j["message"] as? String) ?? "AWS API エラー (\(code))")
        }
        return j
    }
}

extension Meal {
    /// AWS API JSON (ISO date strings) -> Meal
    static func fromJSON(_ j: [String: Any]) -> Meal? {
        guard let id = j["id"] as? String else { return nil }
        var d = j
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        for k in ["takenAt", "createdAt", "aiAt"] {
            if let s = j[k] as? String, let date = f.date(from: s) ?? f2.date(from: s) { d[k] = Timestamp(date: date) }
        }
        for k in ["lat", "lng", "aiConfidence"] { if let n = j[k] as? NSNumber { d[k] = n.doubleValue } }
        return Meal(id: id, data: d)
    }
}
