import Foundation

enum BackendKind: String, CaseIterable, Identifiable {
    case gcp, aws
    var id: String { rawValue }
    var label: String { self == .gcp ? "GCP（通常）" : "AWS（BCP）" }
}

/// Data layer used by the UI. Firebase (GCP) is the primary; AWS is the BCP copy.
@MainActor
protocol MealBackend: AnyObject {
    var kind: BackendKind { get }
    func start(onChange: @escaping ([Meal]) -> Void, onError: @escaping (String) -> Void)
    func stop()
    func refresh() async
    func add(jpeg: Data, takenAt: Date?, lat: Double?, lng: Double?, placeName: String) async throws -> String
    func analyze(mealId: String) async throws
    func update(_ meal: Meal) async throws
    func delete(_ meal: Meal) async throws
    func imageData(path: String) async -> Data?
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
