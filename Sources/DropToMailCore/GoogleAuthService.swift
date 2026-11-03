import Combine
import Foundation

public struct GoogleStoredCredential: Codable, Equatable {
    public let clientID: String
    public let account: GoogleAccount
    public let refreshToken: String
}

public protocol GoogleCredentialStore {
    func read() throws -> GoogleStoredCredential?
    func save(_ credential: GoogleStoredCredential) throws
    func delete() throws
}

public struct KeychainGoogleCredentialStore: GoogleCredentialStore {
    private let account = "google-oauth-credential"
    public init() {}
    public func read() throws -> GoogleStoredCredential? {
        guard let data = try KeychainService.readData(account: account) else { return nil }
        guard let credential = try? JSONDecoder().decode(GoogleStoredCredential.self, from: data),
              !credential.refreshToken.isEmpty, !credential.account.subject.isEmpty,
              AppSettings.isValidEmail(credential.account.email) else { throw KeychainError.invalidData }
        return credential
    }
    public func save(_ credential: GoogleStoredCredential) throws {
        try KeychainService.saveData(JSONEncoder().encode(credential), account: account)
    }
    public func delete() throws { try KeychainService.deleteData(account: account) }
}

@MainActor
public final class GoogleAuthService: ObservableObject {
    @Published public private(set) var account: GoogleAccount?
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    @Published public private(set) var messageIsError = false

    private let configurationLoader: () throws -> GoogleOAuthConfiguration
    private let store: GoogleCredentialStore
    private let client: GoogleOAuthClient
    private let browser: GoogleAuthorizationBrowser
    private var credential: GoogleStoredCredential?
    private var cachedToken: String?
    private var tokenDeadline: ContinuousClock.Instant?

    public init(
        configurationLoader: @escaping () throws -> GoogleOAuthConfiguration = { try .load() },
        store: GoogleCredentialStore = KeychainGoogleCredentialStore(),
        client: GoogleOAuthClient = GoogleOAuthHTTPClient(),
        browser: GoogleAuthorizationBrowser? = nil
    ) {
        self.configurationLoader = configurationLoader
        self.store = store
        self.client = client
        self.browser = browser ?? LoopbackGoogleAuthorizationBrowser()
        do {
            credential = try store.read()
            // Cached identity is display-only until accessToken() validates the session.
            account = credential?.account
        } catch { report(error) }
    }

    /// A failed/cancelled account change preserves the previous account and credential.
    public func authenticate() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let configuration = try configurationLoader()
            let request = try OAuthAuthorizationRequest()
            let authorization = try await browser.authorize(configuration: configuration, request: request)
            try Task.checkCancellation()
            let tokens = try await client.exchange(code: authorization.code, verifier: request.verifier,
                                                   redirectURI: authorization.redirectURI, configuration: configuration)
            try tokens.validate(requireScopes: true)
            guard let refresh = tokens.refresh_token, !refresh.isEmpty else { throw GoogleAuthError.missingRefreshToken }
            let account = try await client.account(accessToken: tokens.access_token)
            try Task.checkCancellation()
            let saved = GoogleStoredCredential(clientID: configuration.clientID, account: account, refreshToken: refresh)
            try store.save(saved)
            credential = saved
            self.account = account
            cache(tokens)
            messageIsError = false
            message = "Google account connected."
        } catch is CancellationError {
            messageIsError = false
            message = "Authentication cancelled."
        } catch { report(error) }
    }

    /// Returns an in-memory access token, refreshing it when needed. Never sends mail.
    public func accessToken() async throws -> String {
        guard !isBusy else { throw GoogleAuthError.busy }
        guard let credential else { throw GoogleAuthError.reauthenticationRequired }
        let configuration: GoogleOAuthConfiguration
        do {
            configuration = try configurationLoader()
            guard credential.clientID == configuration.clientID else { throw GoogleAuthError.reauthenticationRequired }
        } catch { report(error); throw error }
        if let cachedToken, let tokenDeadline, ContinuousClock.now < tokenDeadline { return cachedToken }
        isBusy = true
        defer { isBusy = false }
        do {
            let tokens = try await client.refresh(token: credential.refreshToken, configuration: configuration)
            try tokens.validate(requireScopes: false)
            try Task.checkCancellation()
            // Google usually omits refresh_token on refresh; retain the existing one.
            if let rotated = tokens.refresh_token, !rotated.isEmpty {
                let updated = GoogleStoredCredential(clientID: credential.clientID, account: credential.account, refreshToken: rotated)
                try store.save(updated)
                self.credential = updated
            }
            cache(tokens)
            message = nil
            return tokens.access_token
        } catch {
            if error as? GoogleAuthError == .reauthenticationRequired || error as? GoogleAuthError == .missingPermission {
                cachedToken = nil
                tokenDeadline = nil
                account = nil
                self.credential = nil
                do { try store.delete() } catch { report(error); throw error }
            }
            if !(error is CancellationError) { report(error) }
            throw error
        }
    }

    /// A rejected send is not replayed. A later explicit job must refresh authorization.
    public func invalidateAccessToken() {
        cachedToken = nil
        tokenDeadline = nil
        report(GoogleAuthError.reauthenticationRequired)
    }

    public func restoreSession() async {
        guard credential != nil, !isBusy else { return }
        _ = try? await accessToken()
    }

    public func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Delete locally first so a failed remote revocation cannot restore this session.
        do { try store.delete() } catch { report(error); return }
        let refresh = credential?.refreshToken
        credential = nil
        account = nil
        cachedToken = nil
        tokenDeadline = nil
        messageIsError = false
        message = "Google account disconnected."
        if let refresh {
            do { try await client.revoke(token: refresh) }
            catch {
                messageIsError = true
                message = "Disconnected locally. Google access could not be revoked; remove DropToMail access in your Google Account permissions."
            }
        }
    }

    private func cache(_ tokens: GoogleTokenResponse) {
        cachedToken = tokens.access_token
        tokenDeadline = ContinuousClock.now.advanced(by: .seconds(max(0, tokens.expires_in - 60)))
    }

    private func report(_ error: Error) {
        messageIsError = true
        // Only our own safe errors can reach UI; do not include arbitrary transport errors.
        message = (error as? GoogleAuthError)?.localizedDescription
            ?? (error as? KeychainError)?.localizedDescription
            ?? GoogleAuthError.invalidResponse.localizedDescription
    }
}
