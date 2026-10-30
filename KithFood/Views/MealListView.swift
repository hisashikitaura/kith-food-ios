import SwiftUI

struct MealListView: View {
    @EnvironmentObject var store: MealStore

    var body: some View {
        NavigationStack {
            List(store.meals) { meal in
                NavigationLink {
                    MealDetailView(mealId: meal.id)
                } label: {
                    HStack(spacing: 12) {
                        MealThumb(path: meal.photoPath)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.displayDish).font(.headline)
                            Text([meal.genre, meal.placeName].filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let d = meal.takenAt {
                                Text(d.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.meals.isEmpty {
                    ContentUnavailableView("まだ記録がありません", systemImage: "fork.knife",
                                           description: Text("「追加」タブから写真を取り込んでください"))
                }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("一覧")
            .toolbar {
                let n = store.meals.filter(\.needsAI).count
                if n > 0 || store.bulkRunning {
                    Button {
                        Task { await store.analyzeAllFailed() }
                    } label: {
                        if store.bulkRunning { ProgressView() } else { Text("AI再判定(\(n))") }
                    }
                    .disabled(store.bulkRunning)
                }
            }
        }
    }
}
