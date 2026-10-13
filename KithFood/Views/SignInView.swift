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

struct SettingsView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var store: MealStore

    var body: some View {
        NavigationStack {
            List {
                Section("アカウント") { Text(auth.email ?? "-") }
                Section("記録") { Text("\(store.meals.count) 件") }
                Section { Button("ログアウト", role: .destructive) { auth.signOut() } }
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
