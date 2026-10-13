import SwiftUI
import PhotosUI
import CoreLocation

struct ImportDraft: Identifiable {
    let id = UUID()
    let preview: UIImage
    let jpeg: Data
    let info: PhotoInfo
    var candidates: [PlaceCandidate] = []
    var placeName = ""
    var saved = false
}

struct ImportView: View {
    @EnvironmentObject var store: MealStore
    @State private var selection: [PhotosPickerItem] = []
    @State private var drafts: [ImportDraft] = []
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var denied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $selection, maxSelectionCount: 20,
                                 matching: .images, photoLibrary: .shared()) {
                        Label("写真を選ぶ（最大20枚）", systemImage: "photo.on.rectangle.angled")
                    }
                    if denied {
                        Text("写真へのフルアクセスがないと位置情報を読めない場合があります。設定アプリで許可してください。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if loading { ProgressView("読み込み中…") }
                }
                ForEach($drafts) { $d in
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(uiImage: d.preview).resizable().scaledToFill()
                                .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(d.info.date?.formatted(date: .abbreviated, time: .shortened) ?? "日時不明")
                                Text(d.info.location == nil ? "位置情報なし" : "位置情報あり")
                                    .font(.caption).foregroundStyle(d.info.location == nil ? .orange : .secondary)
                                if d.saved { Label("保存済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                        }
                        if !d.candidates.isEmpty {
                            Picker("近くの店", selection: $d.placeName) {
                                Text("選択なし").tag("")
                                ForEach(d.candidates) { c in Text("\(c.name)（\(c.distance)m）").tag(c.name) }
                            }
                        }
                        TextField("店名を入力", text: $d.placeName)
                    }
                    .disabled(d.saved)
                }
                if !drafts.isEmpty {
                    Section {
                        Button {
                            Task { await saveAll() }
                        } label: {
                            if saving { ProgressView() } else { Text("保存してAI判定").frame(maxWidth: .infinity) }
                        }
                        .disabled(saving || drafts.allSatisfy(\.saved))
                        Button("クリア", role: .destructive) { drafts = []; selection = [] }
                    }
                }
                if let message { Text(message).font(.footnote) }
            }
            .navigationTitle("追加")
            .task { denied = !(await PhotoProcessing.requestAccess()) }
            .onChange(of: selection) { _, items in Task { await load(items) } }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        loading = true; message = nil
        var out: [ImportDraft] = []
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let jpeg = PhotoProcessing.strippedJPEG(from: raw),
                  let preview = UIImage(data: jpeg) else { continue }
            let info = PhotoProcessing.info(localIdentifier: item.itemIdentifier, data: raw)
            var d = ImportDraft(preview: preview, jpeg: jpeg, info: info)
            if let c = info.location {
                d.candidates = await PlaceSearch.nearby(c)
                d.placeName = d.candidates.first?.name ?? ""
            }
            out.append(d)
        }
        drafts = out
        loading = false
    }

    private func saveAll() async {
        saving = true
        var ok = 0
        for i in drafts.indices where !drafts[i].saved {
            let d = drafts[i]
            do {
                _ = try await store.add(jpeg: d.jpeg, takenAt: d.info.date,
                                        lat: d.info.location?.latitude, lng: d.info.location?.longitude,
                                        placeName: d.placeName.trimmingCharacters(in: .whitespaces))
                drafts[i].saved = true; ok += 1
            } catch {
                message = "保存に失敗: \(error.localizedDescription)"
            }
        }
        if ok > 0 { message = "\(ok)件保存しました。AI判定は数秒〜十数秒で反映されます。" }
        saving = false
    }
}
