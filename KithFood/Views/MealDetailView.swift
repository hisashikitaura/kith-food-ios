import SwiftUI

struct MealDetailView: View {
    let mealId: String
    @EnvironmentObject var store: MealStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Meal?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var meal: Meal? { store.meals.first { $0.id == mealId } }

    var body: some View {
        Group {
            if let meal {
                Form {
                    Section {
                        MealPhoto(path: meal.photoPath)
                            .listRowInsets(EdgeInsets())
                    }
                    if editing, let d = Binding($draft) {
                        Section("編集") {
                            TextField("料理名", text: d.dish)
                            Picker("ジャンル", selection: d.genre) {
                                Text("未設定").tag("")
                                ForEach(dishGenres, id: \.self) { Text($0).tag($0) }
                            }
                            TextField("店名", text: d.placeName)
                            TextField("メモ", text: d.memo, axis: .vertical).lineLimit(3...8)
                        }
                    } else {
                        Section {
                            LabeledContent("料理", value: meal.displayDish)
                            LabeledContent("ジャンル", value: meal.genre.isEmpty ? "-" : meal.genre)
                            LabeledContent("店", value: meal.placeName.isEmpty ? "-" : meal.placeName)
                            if let t = meal.takenAt {
                                LabeledContent("日時", value: t.formatted(date: .long, time: .shortened))
                            }
                            if !meal.memo.isEmpty { Text(meal.memo) }
                        }
                        Section("AI") {
                            if !meal.aiComment.isEmpty { Text(meal.aiComment) }
                            if let c = meal.aiConfidence {
                                LabeledContent("確信度", value: "\(Int(c * 100))%")
                            }
                            LabeledContent("状態", value: meal.aiStatus)
                            Button("AIで再判定") { Task { await store.analyze(mealId: meal.id) } }
                                .disabled(meal.aiStatus == "analyzing")
                        }
                        Section {
                            Button("削除", role: .destructive) { confirmDelete = true }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .toolbar {
                    if editing {
                        ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                guard let d = draft else { return }
                                Task {
                                    do { try await store.update(d); editing = false }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    } else {
                        ToolbarItem { Button("編集") { draft = meal; editing = true } }
                    }
                }
                .confirmationDialog("この記録と写真を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        Task {
                            do { try await store.delete(meal); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            } else {
                ContentUnavailableView("削除されました", systemImage: "trash")
            }
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MealPhoto: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.1)
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .task(id: path) { image = await ImageCache.shared.image(path: path) }
    }
}
