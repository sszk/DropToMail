import Foundation
import XCTest
@testable import DropToMailCore

final class GoogleOAuthTests: XCTestCase {
    func testPKCEVectorAndAuthorizationParameters() throws {
        let request = OAuthAuthorizationRequest(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "expected")
        XCTAssertEqual(request.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = request.authorizationURL(configuration: .init(clientID: "test-client"), redirectURI: URL(string: "http://127.0.0.1:1234/")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertEqual(parameters["state"], "expected")
        XCTAssertEqual(parameters["access_type"], "offline")
        XCTAssertEqual(parameters["prompt"], "consent select_account")
        XCTAssertEqual(Set(parameters["scope"]!.split(separator: " ").map(String.init)), Set(GoogleOAuthConfiguration.scopes))
        XCTAssertNil(parameters["client_secret"])
        XCTAssertNil(parameters["code_verifier"])
        let random = try OAuthAuthorizationRequest()
        XCTAssertEqual(random.verifier.count, 43)
        XCTAssertNotEqual(random.verifier, random.state)
        XCTAssertNotEqual(random.state, try OAuthAuthorizationRequest().state)
    }

    func testCallbackRejectsWrongStateHostPortPathAndDuplicates() throws {
        let request = OAuthAuthorizationRequest(verifier: "verifier", state: "expected")
        let redirect = URL(string: "http://127.0.0.1:1234/")!
        XCTAssertEqual(try request.authorizationCode(from: URL(string: "http://127.0.0.1:1234/?state=expected&code=a%2Bb")!, redirectURI: redirect), "a+b")
        for invalid in [
            "http://127.0.0.1:1234/?state=wrong&code=x", "http://localhost:1234/?state=expected&code=x",
            "http://127.0.0.1:4321/?state=expected&code=x", "http://127.0.0.1:1234/other?state=expected&code=x",
            "http://127.0.0.1:1234/?state=expected&state=expected&code=x",
            "http://127.0.0.1:1234/?state=expected&code=x&code=y", "http://127.0.0.1:1234/?state=expected",
            "http://127.0.0.1:1234/?state=expected&code=x#fragment"
        ] { XCTAssertThrowsError(try request.authorizationCode(from: URL(string: invalid)!, redirectURI: redirect)) }
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "http://127.0.0.1:1234/?state=expected&error=access_denied")!, redirectURI: redirect)) {
            XCTAssertEqual($0 as? GoogleAuthError, .denied)
        }
    }

    func testDesktopConfigurationRequiresInstalledClient() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"public-desktop-value"}}"#.utf8).write(to: url)
        XCTAssertEqual(try GoogleOAuthConfiguration.load(from: url).clientID, "test.apps.googleusercontent.com")
        try Data(#"{"web":{"client_id":"test.apps.googleusercontent.com"}}"#.utf8).write(to: url)
        XCTAssertThrowsError(try GoogleOAuthConfiguration.load(from: url))
    }

    func testFormEncodingPreservesReservedCharacters() {
        let request = GoogleOAuthHTTPClient.formRequest(url: "https://oauth2.googleapis.com/token", fields: ["code": "a+b&c=d /あ"])
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "code=a%2Bb%26c%3Dd%20%2F%E3%81%82")
    }
}

@MainActor
final class GoogleAuthServiceTests: XCTestCase {
    private let configuration = GoogleOAuthConfiguration(clientID: "test.apps.googleusercontent.com")
    private let oldAccount = GoogleAccount(subject: "old-subject", email: "old@example.com")

    private func service(store: MemoryCredentialStore, client: MockOAuthClient, browser: MockAuthorizationBrowser? = nil) -> GoogleAuthService {
        GoogleAuthService(configurationLoader: { self.configuration }, store: store, client: client, browser: browser ?? MockAuthorizationBrowser())
    }

    func testSignInSavesRefreshTokenAndCachesAccessToken() async throws {
        let store = MemoryCredentialStore()
        let client = MockOAuthClient()
        let auth = service(store: store, client: client)
        await auth.authenticate()
        XCTAssertEqual(auth.account, client.identity)
        XCTAssertEqual(store.value?.refreshToken, "refresh-token")
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "access-token")
        XCTAssertEqual(client.refreshCount, 0)
        XCTAssertFalse(auth.isBusy)
    }

    func testRejectedSendInvalidatesCachedAccessTokenForNextExplicitAttempt() async throws {
        let store = MemoryCredentialStore()
        let client = MockOAuthClient()
        let auth = service(store: store, client: client)
        await auth.authenticate()
        auth.invalidateAccessToken()
        XCTAssertEqual(auth.message, GoogleAuthError.reauthenticationRequired.localizedDescription)
        _ = try await auth.accessToken()
        XCTAssertEqual(client.refreshCount, 1)
        XCTAssertNotNil(store.value)
    }

    func testRestoredSessionRefreshesAndPreservesOrRotatesRefreshToken() async throws {
        let store = MemoryCredentialStore(value: .init(clientID: configuration.clientID, account: oldAccount, refreshToken: "original"))
        let client = MockOAuthClient()
        client.tokens = .init(access_token: "refreshed", expires_in: 30, token_type: "Bearer", refresh_token: nil, scope: nil)
        let auth = service(store: store, client: client)
        let first = try await auth.accessToken()
        XCTAssertEqual(first, "refreshed")
        XCTAssertEqual(store.value?.refreshToken, "original")
        client.tokens = .init(access_token: "rotated-access", expires_in: 3600, token_type: "Bearer", refresh_token: "rotated", scope: nil)
        let second = try await auth.accessToken()
        XCTAssertEqual(second, "rotated-access")
        XCTAssertEqual(store.value?.refreshToken, "rotated")
        XCTAssertEqual(client.refreshCount, 2)
    }

    func testInvalidGrantClearsSessionAndRequestsReauthentication() async {
        let store = MemoryCredentialStore(value: .init(clientID: configuration.clientID, account: oldAccount, refreshToken: "expired"))
        let client = MockOAuthClient()
        client.failure = .reauthenticationRequired
        let auth = service(store: store, client: client)
        await auth.restoreSession()
        XCTAssertNil(auth.account)
        XCTAssertNil(store.value)
        XCTAssertTrue(auth.messageIsError)
        XCTAssertEqual(auth.message, GoogleAuthError.reauthenticationRequired.localizedDescription)
    }

    func testNetworkFailureKeepsRefreshTokenForRetry() async {
        let saved = GoogleStoredCredential(clientID: configuration.clientID, account: oldAccount, refreshToken: "original")
        let store = MemoryCredentialStore(value: saved)
        let client = MockOAuthClient()
        client.failure = .network
        let auth = service(store: store, client: client)
        await auth.restoreSession()
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(auth.account, oldAccount)
    }

    func testFailedAccountChangeAndKeychainFailurePreserveOldAccount() async {
        let saved = GoogleStoredCredential(clientID: configuration.clientID, account: oldAccount, refreshToken: "old-token")
        let store = MemoryCredentialStore(value: saved)
        let client = MockOAuthClient()
        let browser = MockAuthorizationBrowser()
        let auth = service(store: store, client: client, browser: browser)
        browser.failure = CancellationError()
        await auth.authenticate()
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(auth.account, oldAccount)
        browser.failure = nil
        store.failSave = true
        await auth.authenticate()
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(auth.account, oldAccount)
        XCTAssertTrue(auth.messageIsError)
        store.failSave = false
        await auth.authenticate()
        XCTAssertEqual(auth.account, client.identity)
        XCTAssertEqual(store.value?.account, client.identity)
    }

    func testCancellationDuringAccountLookupDoesNotSaveOrReplaceAccount() async throws {
        let saved = GoogleStoredCredential(clientID: configuration.clientID, account: oldAccount, refreshToken: "original")
        let store = MemoryCredentialStore(value: saved)
        let client = MockOAuthClient()
        client.delayAccountLookup = true
        let auth = service(store: store, client: client)
        let task = Task { await auth.authenticate() }
        while !client.accountLookupStarted { await Task.yield() }
        XCTAssertTrue(auth.isBusy)
        // Concurrent account changes and disconnects must not race this operation.
        await auth.disconnect()
        XCTAssertEqual(store.value, saved)
        task.cancel()
        await task.value
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(auth.account, oldAccount)
        XCTAssertFalse(auth.isBusy)
    }

    func testMissingScopeOrRefreshTokenDoesNotConnect() async {
        let store = MemoryCredentialStore()
        let client = MockOAuthClient()
        client.tokens = .init(access_token: "access", expires_in: 3600, token_type: "Bearer", refresh_token: "refresh", scope: "openid email")
        let auth = service(store: store, client: client)
        await auth.authenticate()
        XCTAssertNil(auth.account)
        XCTAssertNil(store.value)
        XCTAssertEqual(auth.message, GoogleAuthError.missingPermission.localizedDescription)
        client.tokens = .init(access_token: "access", expires_in: 3600, token_type: "Bearer", refresh_token: nil, scope: GoogleOAuthConfiguration.scopes.joined(separator: " "))
        await auth.authenticate()
        XCTAssertEqual(auth.message, GoogleAuthError.missingRefreshToken.localizedDescription)
    }

    func testDisconnectDeletesLocalCredentialsEvenWhenRevocationFails() async {
        let store = MemoryCredentialStore(value: .init(clientID: configuration.clientID, account: oldAccount, refreshToken: "to-revoke"))
        let client = MockOAuthClient()
        client.failure = .network
        let auth = service(store: store, client: client)
        await auth.disconnect()
        XCTAssertNil(auth.account)
        XCTAssertNil(store.value)
        XCTAssertEqual(client.revoked, "to-revoke")
        XCTAssertTrue(auth.messageIsError)
    }

    func testChangedClientIDCannotUseSavedCredential() async {
        let store = MemoryCredentialStore(value: .init(clientID: "different-client", account: oldAccount, refreshToken: "old"))
        let client = MockOAuthClient()
        let auth = service(store: store, client: client)
        do { _ = try await auth.accessToken(); XCTFail("Expected reauthentication") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .reauthenticationRequired) }
        XCTAssertEqual(client.refreshCount, 0)
    }

}

private final class MemoryCredentialStore: GoogleCredentialStore {
    var value: GoogleStoredCredential?
    var failSave = false
    init(value: GoogleStoredCredential? = nil) { self.value = value }
    func read() throws -> GoogleStoredCredential? { value }
    func save(_ credential: GoogleStoredCredential) throws {
        if failSave { throw KeychainError.invalidData }
        value = credential
    }
    func delete() throws { value = nil }
}

private final class MockOAuthClient: GoogleOAuthClient {
    var tokens = GoogleTokenResponse(access_token: "access-token", expires_in: 3600, token_type: "Bearer", refresh_token: "refresh-token", scope: GoogleOAuthConfiguration.scopes.joined(separator: " "))
    var identity = GoogleAccount(subject: "new-subject", email: "new@example.com")
    var refreshCount = 0
    var failure: GoogleAuthError?
    var revoked: String?
    var delayAccountLookup = false
    var accountLookupStarted = false
    func exchange(code: String, verifier: String, redirectURI: URL, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse {
        if let failure { throw failure }
        return tokens
    }
    func refresh(token: String, configuration: GoogleOAuthConfiguration) async throws -> GoogleTokenResponse {
        refreshCount += 1
        if let failure { throw failure }
        return tokens
    }
    func account(accessToken: String) async throws -> GoogleAccount {
        accountLookupStarted = true
        if delayAccountLookup { try? await Task.sleep(for: .seconds(1)) }
        return identity
    }
    func revoke(token: String) async throws {
        revoked = token
        if let failure { throw failure }
    }
}

@MainActor
private final class MockAuthorizationBrowser: GoogleAuthorizationBrowser {
    var failure: Error?
    func authorize(configuration: GoogleOAuthConfiguration, request: OAuthAuthorizationRequest) async throws -> GoogleAuthorizationCode {
        if let failure { throw failure }
        return .init(code: "auth-code", redirectURI: URL(string: "http://127.0.0.1:1234/")!)
    }
}

@MainActor
final class GoogleAuthorizationBrowserTests: XCTestCase {
    func testLoopbackReceivesCallbackAndIgnoresWrongState() async throws {
        let configuration = GoogleOAuthConfiguration(clientID: "test-client")
        let request = try OAuthAuthorizationRequest()
        var callbackTask: Task<Void, Error>?
        let browser = LoopbackGoogleAuthorizationBrowser(openBrowser: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = URL(string: items.first { $0.name == "redirect_uri" }!.value!)!
            XCTAssertEqual(redirect.host, "127.0.0.1")
            XCTAssertNotNil(redirect.port)
            callbackTask = Task {
                var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
                callback.queryItems = [.init(name: "state", value: "wrong"), .init(name: "code", value: "ignored")]
                let (_, rejected) = try await URLSession.shared.data(from: callback.url!)
                XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
                callback.queryItems = [.init(name: "state", value: request.state), .init(name: "code", value: "expected-code")]
                let (_, accepted) = try await URLSession.shared.data(from: callback.url!)
                XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
            }
            return true
        }, timeout: .seconds(5))
        let code = try await browser.authorize(configuration: configuration, request: request)
        XCTAssertEqual(code.code, "expected-code")
        try await callbackTask?.value
    }

    func testTimeoutCancellationAndBrowserFailureReleaseListener() async throws {
        let configuration = GoogleOAuthConfiguration(clientID: "test-client")
        let request = try OAuthAuthorizationRequest()
        let browser = LoopbackGoogleAuthorizationBrowser(openBrowser: { _ in true }, timeout: .milliseconds(30))
        do { _ = try await browser.authorize(configuration: configuration, request: request); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .timedOut) }
        let task = Task { try await browser.authorize(configuration: configuration, request: request) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let unavailable = LoopbackGoogleAuthorizationBrowser(openBrowser: { _ in false })
        do { _ = try await unavailable.authorize(configuration: configuration, request: request); XCTFail("Expected browser error") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .browserUnavailable) }
    }
}

final class GoogleOAuthHTTPClientTests: XCTestCase {
    private func client(status: Int, body: String, inspect: @escaping (URLRequest) -> Void = { _ in }) -> GoogleOAuthHTTPClient {
        StubGoogleURLProtocol.handler = { request in
            inspect(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGoogleURLProtocol.self]
        return GoogleOAuthHTTPClient(session: URLSession(configuration: configuration))
    }

    func testExchangeUsesPOSTWithVerifierAndRedirect() async throws {
        let client = client(status: 200, body: #"{"access_token":"access","expires_in":3600,"token_type":"Bearer"}"#) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            // URLSession can turn httpBody into httpBodyStream before URLProtocol sees it.
            var body = request.httpBody
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count > 0 { body = Data(bytes.prefix(count)) }
            }
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("code_verifier=test-verifier"))
            XCTAssertTrue(text.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1234%2F"))
            XCTAssertTrue(text.contains("client_secret=desktop-value"))
        }
        _ = try await client.exchange(code: "test-code", verifier: "test-verifier", redirectURI: URL(string: "http://127.0.0.1:1234/")!, configuration: .init(clientID: "client", clientSecret: "desktop-value"))
    }

    func testUserInfoRequiresVerifiedWorkspaceEmail() async throws {
        let valid = client(status: 200, body: #"{"sub":"subject","email":"person@example.com","email_verified":true,"hd":"example.com"}"#) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNil(request.url?.query)
        }
        let account = try await valid.account(accessToken: "test-token")
        XCTAssertEqual(account.email, "person@example.com")
        let consumer = client(status: 200, body: #"{"sub":"subject","email":"person@example.com","email_verified":true}"#)
        do { _ = try await consumer.account(accessToken: "token"); XCTFail("Expected Workspace account requirement") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .workspaceAccountRequired) }
    }

    func testInvalidGrantAndServerErrorsAreSanitized() async {
        for (status, body, expected) in [
            (400, #"{"error":"invalid_grant","error_description":"private-token"}"#, GoogleAuthError.reauthenticationRequired),
            (503, "private-token", GoogleAuthError.server(503)),
            (200, "invalid-json", GoogleAuthError.invalidResponse)
        ] {
            let client = client(status: status, body: body)
            do { _ = try await client.refresh(token: "token", configuration: .init(clientID: "client")); XCTFail("Expected error") }
            catch {
                XCTAssertEqual(error as? GoogleAuthError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-token"))
            }
        }
    }
}

private final class StubGoogleURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
