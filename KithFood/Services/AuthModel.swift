import Foundation
import UIKit
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

@MainActor
final class AuthModel: ObservableObject {
    @Published var uid: String?
    @Published var email: String?
    @Published var errorMessage: String?
    @Published var isLoading = false

    /// Same allow-list as the diary app (Firestore/Storage rules enforce it too).
    private let allowedEmail = "owner@example.com"
    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.uid = user?.uid
                self?.email = user?.email
            }
        }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "GoogleService-Info.plist がありません"
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else {
            errorMessage = "画面が見つかりません"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
            guard result.user.profile?.email == allowedEmail else {
                GIDSignIn.sharedInstance.signOut()
                errorMessage = "このアカウントは使用できません"
                return
            }
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "トークンを取得できませんでした"
                return
            }
            let cred = GoogleAuthProvider.credential(withIDToken: idToken,
                                                     accessToken: result.user.accessToken.tokenString)
            try await Auth.auth().signIn(with: cred)
        } catch {
            errorMessage = "ログインに失敗しました: \(error.localizedDescription)"
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }
}
