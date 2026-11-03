import CryptoKit
import Foundation
import Security

public struct GoogleOAuthConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public static let scopes = ["https://www.googleapis.com/auth/gmail.send", "openid", "email"]

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropToMail/google-oauth.json")
    }

    public static func load(from url: URL = configurationURL) throws -> Self {
        struct Document: Decodable {
            struct Installed: Decodable {
                let client_id: String
                let client_secret: String?
            }
            let installed: Installed
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.installed.client_id.hasSuffix(".apps.googleusercontent.com"),
              !document.installed.client_id.contains(where: { $0.isWhitespace })
        else { throw GoogleAuthError.configuration }
        return Self(clientID: document.installed.client_id, clientSecret: document.installed.client_secret)
    }
}

public enum GoogleAuthError: Error, LocalizedError, Equatable {
    case configuration, invalidCallback, denied, timedOut, browserUnavailable, listenerFailed
    case invalidResponse, missingPermission, missingRefreshToken, reauthenticationRequired
    case network, server(Int), busy, workspaceAccountRequired

    public var errorDescription: String? {
        switch self {
        case .configuration: return "Place a Desktop app OAuth JSON file at ~/Library/Application Support/DropToMail/google-oauth.json, then authenticate again. See README for setup."
        case .invalidCallback: return "The Google authentication callback could not be verified."
        case .denied: return "Google authentication was denied. Authenticate again to grant access."
        case .timedOut: return "Google authentication timed out. Please try again."
        case .browserUnavailable: return "Could not open the default browser."
        case .listenerFailed: return "Could not receive the local Google authentication callback."
        case .invalidResponse: return "Google returned an invalid authentication response."
        case .missingPermission: return "Google did not grant the required email and Gmail send permissions. Authenticate again and allow these permissions."
        case .missingRefreshToken: return "Google did not issue a refresh token. Please authenticate again."
        case .reauthenticationRequired: return "Google authorization has expired or been revoked. Authenticate again in Settings."
        case .workspaceAccountRequired: return "Use a Google Workspace account with a verified email address."
        case .network: return "Could not connect to Google. Check your network connection and try again."
        case .server(let status): return "Google authentication failed (HTTP \(status)). Please try again."
        case .busy: return "A Google account operation is already in progress."
        }
    }
}

public struct OAuthAuthorizationRequest: Sendable {
    public let verifier: String
    public let state: String

    public init() throws {
        verifier = try Self.randomToken()
        state = try Self.randomToken()
    }

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
    }

    public var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    public func authorizationURL(configuration: GoogleOAuthConfiguration, redirectURI: URL) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        return components.url!
    }

    public func authorizationCode(from callback: URL, redirectURI: URL) throws -> String {
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { throw GoogleAuthError.invalidCallback }
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard items.filter({ $0.name == "state" }).count == 1, values("state") == [state] else {
            throw GoogleAuthError.invalidCallback
        }
        if !values("error").isEmpty { throw GoogleAuthError.denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = values("code").first, !code.isEmpty else { throw GoogleAuthError.invalidCallback }
        return code
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleAuthError.invalidResponse
        }
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct GoogleTokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let token_type: String
    let refresh_token: String?
    let scope: String?

    func validate(requireScopes: Bool) throws {
        guard !access_token.isEmpty, expires_in.isFinite, expires_in > 0,
              token_type.lowercased() == "bearer" else { throw GoogleAuthError.invalidResponse }
        if requireScopes || scope != nil {
            let granted = Set((scope ?? "").split(separator: " ").map(String.init))
            guard granted.contains(GoogleOAuthConfiguration.scopes[0]), granted.contains("openid"),
                  granted.contains("email") || granted.contains("https://www.googleapis.com/auth/userinfo.email")
            else { throw GoogleAuthError.missingPermission }
        }
    }
}

public struct GoogleAccount: Codable, Equatable {
    public let subject: String
    public let email: String
}

public protocol GoogleOAuthClient {
    func exchange(code: String, verifier: String, redirectURI: URL, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse
    func refresh(token: String, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse
    func account(accessToken: String) async throws -> GoogleAccount
    func revoke(token: String) async throws
}

public final class GoogleOAuthHTTPClient: GoogleOAuthClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func exchange(code: String, verifier: String, redirectURI: URL, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse {
        try await tokens(fields: ["grant_type": "authorization_code", "code": code,
                                  "code_verifier": verifier, "redirect_uri": redirectURI.absoluteString], configuration: configuration)
    }

    public func refresh(token: String, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse {
        try await tokens(fields: ["grant_type": "refresh_token", "refresh_token": token], configuration: configuration)
    }

    private func tokens(fields: [String: String], configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse {
        var fields = fields
        fields["client_id"] = configuration.clientID
        fields["client_secret"] = configuration.clientSecret
        let data = try await perform(Self.formRequest(url: "https://oauth2.googleapis.com/token", fields: fields))
        guard let tokens = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else { throw GoogleAuthError.invalidResponse }
        return tokens
    }

    public func account(accessToken: String) async throws -> GoogleAccount {
        struct UserInfo: Decodable {
            let sub: String
            let email: String
            let email_verified: Bool
            let hd: String?
        }
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        guard let info = try? JSONDecoder().decode(UserInfo.self, from: data),
              info.email_verified, !info.sub.isEmpty, AppSettings.isValidEmail(info.email),
              let domain = info.hd, !domain.isEmpty else { throw GoogleAuthError.workspaceAccountRequired }
        return GoogleAccount(subject: info.sub, email: info.email)
    }

    public func revoke(token: String) async throws {
        _ = try await perform(Self.formRequest(url: "https://oauth2.googleapis.com/revoke", fields: ["token": token]))
    }

    static func formRequest(url: String, fields: [String: String]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw GoogleAuthError.network }
        guard let response = response as? HTTPURLResponse else { throw GoogleAuthError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            if code == "invalid_grant" || response.statusCode == 401 { throw GoogleAuthError.reauthenticationRequired }
            if code == "access_denied" { throw GoogleAuthError.denied }
            // Never expose response bodies: they can contain credentials or personal information.
            throw GoogleAuthError.server(response.statusCode)
        }
        return data
    }
}
