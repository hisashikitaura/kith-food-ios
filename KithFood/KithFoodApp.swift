import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct KithFoodApp: App {
    @StateObject private var auth: AuthModel
    @StateObject private var awsAuth = AWSAuth()
    @StateObject private var store = MealStore()

    init() {
        FirebaseApp.configure()
        _auth = StateObject(wrappedValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(awsAuth)
                .environmentObject(store)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var awsAuth: AWSAuth
    @EnvironmentObject var store: MealStore
    @AppStorage("backend") private var backendRaw = BackendKind.gcp.rawValue

    private var backend: BackendKind { BackendKind(rawValue: backendRaw) ?? .gcp }

    var body: some View {
        Group {
            switch backend {
            case .gcp:
                if let uid = auth.uid {
                    MainTabView().onAppear { store.start(uid: uid) }
                } else {
                    SignInView().onAppear { store.stop() }
                }
            case .aws:
                if awsAuth.isSignedIn {
                    MainTabView().onAppear { store.startAWS(auth: awsAuth) }
                } else {
                    AWSSignInView().onAppear { store.stop() }
                }
            }
        }
        .id(backendRaw + (auth.uid ?? "") + (awsAuth.isSignedIn ? "1" : "0"))
    }
}

struct MainTabView: View {
    @EnvironmentObject var store: MealStore

    var body: some View {
        TabView {
            MealMapView().tabItem { Label("マップ", systemImage: "map") }
            MealListView().tabItem { Label("一覧", systemImage: "list.bullet") }
            ImportView().tabItem { Label("追加", systemImage: "plus.circle") }
            SettingsView().tabItem { Label("設定", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.kind == .aws { AWSBanner() }
        }
    }
}

struct AWSBanner: View {
    var body: some View {
        Label("AWSモード(低リスク切替)", systemImage: "exclamationmark.shield.fill")
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.orange)
    }
}
