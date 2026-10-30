import SwiftUI

struct SignInView: View {
    @EnvironmentObject var auth: AuthModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 80)).foregroundStyle(.tint)
            Text("Kith Food").font(.largeTitle.bold())
            Text("料理の写真を地図と図鑑に").foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await auth.signInWithGoogle() }
            } label: {
                Label("Googleでログイン", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(auth.isLoading)
            if let e = auth.errorMessage { Text(e).foregroundStyle(.red).font(.footnote) }
        }
        .padding(32)
    }
}

struct AWSSignInView: View {
    @EnvironmentObject var awsAuth: AWSAuth
    @AppStorage("backend") private var backendRaw = BackendKind.gcp.rawValue

    var body: some View {
        VStack(spacing: 20) {
            AWSBanner().clipShape(Capsule())
            Spacer()
            Image(systemName: "cloud.fill").font(.system(size: 72)).foregroundStyle(.orange)
            Text("AWS（BCP）にログイン").font(.title2.bold())
            Text("Google アカウントで AWS Cognito にログインします。AWSモードでの変更は GCP に自動では戻りません。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            if AWSConfig.shared == nil {
                Text("AWSConfig.plist が入っていません").foregroundStyle(.red).font(.footnote)
            }
            Button {
                Task { await awsAuth.signIn() }
            } label: {
                Label("Googleでログイン（AWS）", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            .disabled(awsAuth.isLoading || AWSConfig.shared == nil)
            if let e = awsAuth.errorMessage { Text(e).foregroundStyle(.red).font(.footnote) }
            Button("GCP に戻す") { backendRaw = BackendKind.gcp.rawValue }
        }
        .padding(32)
    }
}

struct SettingsView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var awsAuth: AWSAuth
    @EnvironmentObject var store: MealStore
    @AppStorage("backend") private var backendRaw = BackendKind.gcp.rawValue
    @State private var backfillMessage: String?
    @State private var backfilling = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("接続先", selection: $backendRaw) {
                        ForEach(BackendKind.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("バックエンド")
                } footer: {
                    Text("GCP の記録は数秒以内に AWS へ自動コピーされます（片方向）。AWSモードで追加・編集・削除した内容は GCP に自動では戻りません（aws/restore-to-gcp 参照）。")
                }
                if store.kind == .gcp {
                    Section("アカウント（GCP）") { Text(auth.email ?? "-") }
                    Section {
                        Button {
                            Task {
                                guard let fb = store.backend as? FirebaseBackend else { return }
                                backfilling = true
                                do { backfillMessage = try await fb.backfillToAWS() }
                                catch { backfillMessage = "失敗: \(error.localizedDescription)" }
                                backfilling = false
                            }
                        } label: {
                            if backfilling { ProgressView() } else { Text("AWSへ全件コピー（初回・再同期）") }
                        }
                        .disabled(backfilling)
                        if let backfillMessage { Text(backfillMessage).font(.footnote) }
                    } header: { Text("BCP") }
                } else {
                    Section("アカウント（AWS）") { Text(awsAuth.email ?? "-") }
                }
                Section("記録") { Text("\(store.meals.count) 件") }
                Section {
                    if store.kind == .gcp {
                        Button("ログアウト", role: .destructive) { auth.signOut() }
                    } else {
                        Button("AWSからログアウト", role: .destructive) { awsAuth.signOut() }
                    }
                }
            }
            .navigationTitle("設定")
        }
    }
}

struct MealThumb: View {
    let path: String
    var size: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) { image = await ImageCache.shared.image(path: path) }
    }
}
