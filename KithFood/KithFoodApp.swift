import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct KithFoodApp: App {
    @StateObject private var auth = AuthModel()
    @StateObject private var store = MealStore()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var store: MealStore

    var body: some View {
        Group {
            if let uid = auth.uid {
                MainTabView()
                    .onAppear { store.start(uid: uid) }
            } else {
                SignInView()
                    .onAppear { store.stop() }
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            MealMapView().tabItem { Label("マップ", systemImage: "map") }
            MealListView().tabItem { Label("一覧", systemImage: "list.bullet") }
            ImportView().tabItem { Label("追加", systemImage: "plus.circle") }
            SettingsView().tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}
