import Foundation

/// Non-secret AWS endpoints, read from AWSConfig.plist (gitignored; see aws/AWSConfig.example.plist).
struct AWSConfig {
    let apiBaseURL: URL
    let cognitoDomain: String   // e.g. xxx.auth.ap-northeast-1.amazoncognito.com
    let clientId: String
    let redirectURI = "kithfood://auth"

    static let shared: AWSConfig? = {
        guard let url = Bundle.main.url(forResource: "AWSConfig", withExtension: "plist"),
              let d = NSDictionary(contentsOf: url) as? [String: String],
              let api = d["ApiBaseURL"].flatMap(URL.init(string:)),
              let domain = d["CognitoDomain"], let client = d["ClientId"],
              !domain.isEmpty, !client.isEmpty else { return nil }
        return AWSConfig(apiBaseURL: api, cognitoDomain: domain, clientId: client)
    }()
}
