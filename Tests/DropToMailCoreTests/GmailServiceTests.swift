import Foundation
import XCTest
@testable import DropToMailCore

final class GmailServiceTests: XCTestCase {
    private func service(handler: @escaping (URLRequest, URLProtocol) throws -> Void) -> GmailService {
        GmailURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GmailURLProtocol.self]
        return GmailService(session: URLSession(configuration: configuration))
    }

    func testSendsBase64URLMIMEOnceAndRequiresMessageID() async throws {
        let message = Data([0xfb, 0xff, 0x00, 0x01])
        var count = 0
        let client = service { request, stub in
            count += 1
            XCTAssertEqual(request.url?.absoluteString, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
            let body = try Self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, ["raw": "-_8AAQ"])
            Self.respond(stub, status: 200, body: #"{"id":"gmail-message-id","threadId":"thread"}"#)
        }
        let receipt = try await client.send(message: message, accessToken: "test-token")
        XCTAssertEqual(receipt.messageID, "gmail-message-id")
        XCTAssertEqual(count, 1)
    }

    func testAPIErrorCategoriesAndSanitizedMessagesWithoutRetries() async {
        let cases: [(Int, String, GmailError)] = [
            (401, "private-response", .authentication),
            (403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}],"message":"private-response"}}"#, .insufficientScope),
            (403, #"{"error":{"errors":[{"reason":"domainPolicy"}]}}"#, .workspacePolicy),
            (403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#, .rateLimited),
            (403, #"{"error":{"errors":[{"reason":"dailyLimitExceeded"}]}}"#, .rateLimited),
            (429, "", .rateLimited), (413, "", .messageTooLarge),
            (400, #"{"error":{"message":"Message too large: private-response"}}"#, .messageTooLarge),
            (400, "private-response", .rejected), (302, "", .rejected),
            (500, "", .outcomeUnknown), (503, "", .outcomeUnknown), (408, "", .outcomeUnknown),
            (200, "invalid-json", .outcomeUnknown), (200, #"{"id":""}"#, .outcomeUnknown),
            (204, "", .outcomeUnknown)
        ]
        for (status, body, expected) in cases {
            var count = 0
            let client = service { _, stub in count += 1; Self.respond(stub, status: status, body: body) }
            do { _ = try await client.send(message: Data("mime".utf8), accessToken: "test-token"); XCTFail("Expected error for \(status)") }
            catch {
                XCTAssertEqual(error as? GmailError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-response"))
            }
            XCTAssertEqual(count, 1)
        }
    }

    func testPermissionFailuresDistinguishAPIConfigurationScopeAndDomainPolicy() async throws {
        let cases: [(String, GmailError)] = [
            (#"{"error":{"errors":[{"reason":"accessNotConfigured"}]}}"#, .apiDisabled),
            (#"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","metadata":{"consumer":"private-project","token":"private-token"}}]}}"#, .apiDisabled),
            (#"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#, .insufficientScope),
            (#"{"error":{"errors":[{"reason":"domainPolicy"}]}}"#, .workspacePolicy),
            (#"{"error":{"errors":[{"reason":"forbidden"}]}}"#, .permissionDenied),
            (#"{"error":{"details":[{"@type":"unrelated-detail","reason":"SERVICE_DISABLED"}]}}"#, .permissionDenied),
            (#"{"error":{"errors":[{"reason":"private-token"}],"message":"private-project"}}"#, .permissionDenied),
            ("invalid-json", .permissionDenied)
        ]
        for (body, expected) in cases {
            var count = 0
            let client = service { _, stub in count += 1; Self.respond(stub, status: 403, body: body) }
            do { _ = try await client.send(message: Data("mime".utf8), accessToken: "test-token"); XCTFail("Expected rejection") }
            catch {
                XCTAssertEqual(error as? GmailError, expected)
                XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
                XCTAssertFalse(error.localizedDescription.contains("private-project"))
                XCTAssertFalse(error.localizedDescription.contains("private-token"))
            }
            XCTAssertEqual(count, 1)
        }
    }

    func testTransportFailureDistinguishesConnectionFailureFromUnknownOutcome() async {
        for (code, expected) in [(URLError.notConnectedToInternet, GmailError.network), (.cannotFindHost, .network),
                                  (.timedOut, .outcomeUnknown), (.networkConnectionLost, .outcomeUnknown), (.cancelled, .outcomeUnknown)] {
            var count = 0
            let client = service { _, stub in
                count += 1
                stub.client?.urlProtocol(stub, didFailWithError: URLError(code))
            }
            do { _ = try await client.send(message: Data("mime".utf8), accessToken: "test-token"); XCTFail("Expected transport error") }
            catch { XCTAssertEqual(error as? GmailError, expected) }
            XCTAssertEqual(count, 1)
        }
    }

    func testRejectsRedirectWithoutForwardingCredentialsOrMail() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        let target = URL(string: "https://unexpected.invalid/mail")!
        let task = session.dataTask(with: source) // Never resumed: no external request.
        let response = HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
        var decisionMade = false
        RejectMailRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                        newRequest: URLRequest(url: target)) { request in
            decisionMade = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(decisionMade)
        var requests = 0
        let client = service { _, stub in requests += 1; Self.respond(stub, status: 307, body: "") }
        do { _ = try await client.send(message: Data("mime".utf8), accessToken: "test-token"); XCTFail("Expected rejected redirect") }
        catch { XCTAssertEqual(error as? GmailError, .rejected) }
        XCTAssertEqual(requests, 1)
    }

    func testOversizeAndMissingTokenDoNotStartRequest() async {
        var requests = 0
        let client = service { _, stub in requests += 1; Self.respond(stub, status: 200, body: #"{"id":"unexpected"}"#) }
        do { _ = try await client.send(message: Data(), accessToken: ""); XCTFail("Expected authentication error") }
        catch { XCTAssertEqual(error as? GmailError, .authentication) }
        do { _ = try await client.send(message: Data(count: MIMEMessageBuilder.maximumMessageBytes + 1), accessToken: "test-token"); XCTFail("Expected size error") }
        catch { XCTAssertEqual(error as? GmailError, .messageTooLarge) }
        XCTAssertEqual(requests, 0)
    }

    private static func respond(_ stub: URLProtocol, status: Int, body: String) {
        let response = HTTPURLResponse(url: stub.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
        stub.client?.urlProtocol(stub, didLoad: Data(body.utf8))
        stub.client?.urlProtocolDidFinishLoading(stub)
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}

private final class GmailURLProtocol: URLProtocol {
    static var handler: ((URLRequest, URLProtocol) throws -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { try Self.handler?(request, self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
