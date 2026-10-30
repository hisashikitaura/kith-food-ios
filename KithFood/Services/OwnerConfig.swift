import Foundation

/// Owner's Google account (single-user allow-list), read from OwnerConfig.plist (gitignored;
/// see OwnerConfig.example.plist). Fails closed: if missing, nobody can sign in.
enum OwnerConfig {
    static let email: String? = {
        guard let url = Bundle.main.url(forResource: "OwnerConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let e = dict["OwnerEmail"] as? String, !e.isEmpty else { return nil }
        return e.lowercased()
    }()
}
