import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Cognito Hosted UI (Google federation) via ASWebAuthenticationSession + PKCE.
/// Refresh token is stored in the Keychain; access token stays in memory.
@MainActor
final class AWSAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isSignedIn = false
    @Published private(set) var email: String?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var accessToken: String?
    private var accessExp: Date = .distantPast
    private var session: ASWebAuthenticationSession?
    private let keychainKey = "kithfood.aws.refresh"

    override init() {
        super.init()
        isSignedIn = Keychain.read(keychainKey) != nil
        email = UserDefaults.standard.string(forKey: "kithfood.aws.email")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow ?? ASPresentationAnchor()
        }
    }

    func signIn() async {
        guard let cfg = AWSConfig.shared else { errorMessage = "AWSConfig.plist がありません"; return }
        errorMessage = nil; isLoading = true
        defer { isLoading = false }
        let verifier = Self.randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        var c = URLComponents(string: "https://\(cfg.cognitoDomain)/oauth2/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: cfg.clientId),
            .init(name: "redirect_uri", value: cfg.redirectURI),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "identity_provider", value: "Google"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        do {
            let callback: URL = try await withCheckedThrowingContinuation { cont in
                let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "kithfood") { url, err in
                    if let url { cont.resume(returning: url) } else { cont.resume(throwing: err ?? BackendError(message: "キャンセル")) }
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                self.session = s
                s.start()
            }
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state else { throw BackendError(message: "state不一致") }
            if let e = items.first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
                throw BackendError(message: "ログイン拒否: \(e)")
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else { throw BackendError(message: "codeがありません") }
            try await token(cfg, form: [
                "grant_type": "authorization_code", "client_id": cfg.clientId,
                "code": code, "redirect_uri": cfg.redirectURI, "code_verifier": verifier,
            ])
        } catch {
            errorMessage = "AWSログイン失敗: \(error.localizedDescription)"
        }
    }

    func signOut() {
        Keychain.delete(keychainKey)
        accessToken = nil; accessExp = .distantPast
        isSignedIn = false; email = nil
        UserDefaults.standard.removeObject(forKey: "kithfood.aws.email")
    }

    /// Valid access token (refreshes when it expires within 60s).
    func validAccessToken() async throws -> String {
        if let t = accessToken, accessExp.timeIntervalSinceNow > 60 { return t }
        guard let cfg = AWSConfig.shared, let refresh = Keychain.read(keychainKey) else {
            signOut(); throw BackendError(message: "AWSに再ログインしてください")
        }
        do {
            try await token(cfg, form: ["grant_type": "refresh_token", "client_id": cfg.clientId, "refresh_token": refresh])
        } catch {
            signOut(); throw BackendError(message: "AWSに再ログインしてください")
        }
        guard let t = accessToken else { throw BackendError(message: "トークンなし") }
        return t
    }

    private func token(_ cfg: AWSConfig, form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://\(cfg.cognitoDomain)/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else {
            throw BackendError(message: "トークン取得に失敗")
        }
        accessToken = access
        accessExp = Date().addingTimeInterval(TimeInterval((j["expires_in"] as? Int) ?? 3600))
        if let r = j["refresh_token"] as? String { Keychain.save(keychainKey, r) }
        if let id = j["id_token"] as? String, let mail = Self.claim(id, "email") {
            email = mail
            UserDefaults.standard.set(mail, forKey: "kithfood.aws.email")
        }
        isSignedIn = true
    }

    private static func claim(_ jwt: String, _ key: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j[key] as? String
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum Keychain {
    static func save(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }
}
