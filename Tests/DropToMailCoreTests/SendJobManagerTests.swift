import Foundation
import XCTest
@testable import DropToMailCore

@MainActor
final class SendJobManagerTests: XCTestCase {
    func testCancellingCountdownCleansPreparedArchiveWithoutSending() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ZipService()
        let initialJobs = try jobDirectories()
        let mailer = StubMailSender()
        let manager = SendJobManager(zipService: service, mailService: mailer)
        manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 5, authorize: { "test-token" })
        for _ in 0..<100 {
            if try jobDirectories().count > initialJobs.count { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(manager.state, .countdown(5))
        XCTAssertEqual(try jobDirectories().count, initialJobs.count + 1)
        manager.cancel()
        try await waitUntil { !manager.state.isBusy }
        XCTAssertEqual(manager.state, .cancelled)
        XCTAssertEqual(try jobDirectories(), initialJobs)
        let count = await mailer.callCount
        XCTAssertEqual(count, 0)
    }

    func testExpiredAuthorizationPreventsSendAndCleansArchive() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialJobs = try jobDirectories()
        let mailer = StubMailSender()
        let manager = SendJobManager(mailService: mailer)
        var authorizationCalls = 0
        manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com", password: "zip-pass", waitSeconds: 0) {
            authorizationCalls += 1
            throw GoogleAuthError.reauthenticationRequired
        }
        try await waitUntil { !manager.state.isBusy }
        XCTAssertEqual(manager.state, .error(GoogleAuthError.reauthenticationRequired.localizedDescription))
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(try jobDirectories(), initialJobs)
        let count = await mailer.callCount
        XCTAssertEqual(count, 0)
    }

    func testZeroDelaySendsPreparedMIMEWithAuthorizedTokenAndCleansArchive() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialJobs = try jobDirectories()
        let mailer = StubMailSender()
        let manager = SendJobManager(mailService: mailer)
        manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 0, authorize: { "test-token" })
        try await waitUntil { !manager.state.isBusy }
        XCTAssertEqual(manager.state, .success)
        XCTAssertEqual(try jobDirectories(), initialJobs)
        let count = await mailer.callCount
        let token = await mailer.lastToken
        let message = await mailer.lastMessage
        XCTAssertEqual(count, 1)
        XCTAssertEqual(token, "test-token")
        let mime = String(decoding: try XCTUnwrap(message), as: UTF8.self)
        XCTAssertTrue(mime.contains("From: sender@example.com\r\nTo: person@example.com\r\n"))
        XCTAssertTrue(mime.contains("Content-Type: application/zip"))
        XCTAssertFalse(mime.contains("zip-pass"))
    }

    func testSendErrorsAreNotRetriedAndAlwaysCleanArchive() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialJobs = try jobDirectories()
        for failure in [GmailError.authentication, .permissionDenied, .apiDisabled, .insufficientScope, .workspacePolicy, .rateLimited, .outcomeUnknown, .network] {
            let mailer = StubMailSender(failure: failure)
            let manager = SendJobManager(mailService: mailer)
            var authorizationInvalidations = 0
            manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                          password: "zip-pass", waitSeconds: 0, authorize: { "test-token" },
                          onAuthorizationFailure: { authorizationInvalidations += 1 })
            try await waitUntil { !manager.state.isBusy }
            XCTAssertEqual(manager.state, failure == .outcomeUnknown ? .outcomeUnknown : .error(failure.localizedDescription))
            XCTAssertEqual(authorizationInvalidations, failure == .authentication ? 1 : 0)
            XCTAssertEqual(try jobDirectories(), initialJobs)
            let count = await mailer.callCount
            XCTAssertEqual(count, 1)
        }
    }

    func testSendingCannotBeCancelledAndSecondDropIsIgnored() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailer = StubMailSender(suspended: true)
        let manager = SendJobManager(mailService: mailer)
        manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 0, authorize: { "test-token" })
        try await waitUntil { await mailer.callCount == 1 }
        XCTAssertEqual(manager.state, .sending)
        manager.cancel()
        XCTAssertEqual(manager.state, .sending)
        manager.start(inputs: [input], recipient: "other@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 0, authorize: { "unexpected" })
        await mailer.completeSend()
        try await waitUntil { !manager.state.isBusy }
        XCTAssertEqual(manager.state, .success)
        let count = await mailer.callCount
        XCTAssertEqual(count, 1)
    }

    func testCancellationAtAuthorizationBoundaryPreventsSending() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialJobs = try jobDirectories()
        let mailer = StubMailSender()
        let manager = SendJobManager(mailService: mailer)
        var authorization: CheckedContinuation<String, Never>?
        manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 0) {
            await withCheckedContinuation { authorization = $0 }
        }
        try await waitUntil { authorization != nil }
        manager.cancel()
        authorization?.resume(returning: "test-token")
        try await waitUntil { !manager.state.isBusy }
        XCTAssertEqual(manager.state, .cancelled)
        XCTAssertEqual(try jobDirectories(), initialJobs)
        let count = await mailer.callCount
        XCTAssertEqual(count, 0)
    }

    func testZIPFailureDoesNotAuthorizeOrSend() async throws {
        let mailer = StubMailSender()
        let manager = SendJobManager(mailService: mailer)
        var authorized = false
        manager.start(inputs: [], recipient: "person@example.com", sender: "sender@example.com",
                      password: "zip-pass", waitSeconds: 0) { authorized = true; return "test-token" }
        try await waitUntil { !manager.state.isBusy }
        guard case .error = manager.state else { return XCTFail("Expected ZIP failure") }
        XCTAssertFalse(authorized)
        let count = await mailer.callCount
        XCTAssertEqual(count, 0)
    }

    func testAllDelayOptionsCanBeCancelledBeforeSend() async throws {
        let (directory, input) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for seconds in AppSettings.countdownValues {
            let mailer = StubMailSender()
            let manager = SendJobManager(mailService: mailer)
            manager.start(inputs: [input], recipient: "person@example.com", sender: "sender@example.com",
                          password: "zip-pass", waitSeconds: seconds, authorize: { "test-token" })
            XCTAssertEqual(manager.state, seconds == 0 ? .preparing : .countdown(seconds))
            manager.cancel()
            try await waitUntil { !manager.state.isBusy }
            XCTAssertEqual(manager.state, .cancelled)
            let count = await mailer.callCount
            XCTAssertEqual(count, 0)
        }
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let input = directory.appendingPathComponent("報告書 payload.txt")
        try Data("payload".utf8).write(to: input)
        return (directory, input)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for job state")
    }

    private func jobDirectories() throws -> Set<String> {
        let root = ZipService().temporaryRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { UUID(uuidString: $0) != nil })
    }
}

private actor StubMailSender: MailSending {
    var callCount = 0
    var lastMessage: Data?
    var lastToken: String?
    private let failure: GmailError?
    private let suspended: Bool
    private var pending: CheckedContinuation<GmailSendReceipt, Error>?

    init(failure: GmailError? = nil, suspended: Bool = false) {
        self.failure = failure
        self.suspended = suspended
    }
    func send(message: Data, accessToken: String) async throws -> GmailSendReceipt {
        callCount += 1
        lastMessage = message
        lastToken = accessToken
        if let failure { throw failure }
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        return GmailSendReceipt(messageID: "stub-message-id")
    }
    func completeSend() { pending?.resume(returning: GmailSendReceipt(messageID: "stub-message-id")); pending = nil }
}
