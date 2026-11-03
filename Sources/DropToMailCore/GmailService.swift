import Foundation

public enum GmailError: Error, LocalizedError, Equatable {
    case invalidAddress, invalidHeader, attachmentRead, messageTooLarge
    case authentication, permissionDenied, apiDisabled, insufficientScope, workspacePolicy
    case rateLimited, rejected, network, outcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a single valid email address using ASCII characters."
        case .invalidHeader: return "The file name or subject contains unsupported control characters."
        case .attachmentRead: return "The ZIP attachment could not be read or changed during preparation. Drop the files again."
        case .messageTooLarge: return "The ZIP exceeds the 25 MB attachment limit or the encoded message exceeds 35 MB. Reduce the files and try again. Your organization may set a lower limit."
        case .authentication: return "Gmail rejected Google authorization. Reauthenticate in Settings before trying again."
        case .permissionDenied: return "Gmail denied permission to send (HTTP 403). The rejection reason could not be identified. See the Gmail permission troubleshooting steps in README."
        case .apiDisabled: return "Gmail API is disabled or has not been enabled in the OAuth client's Google Cloud project (HTTP 403). Open Google Cloud Console, select the project that owns this OAuth client, and enable Gmail API under APIs & Services > Library. Wait a few minutes before trying again."
        case .insufficientScope: return "Google authorization does not include the required gmail.send permission (HTTP 403). In Settings, choose Change / Reauthenticate and grant permission to send email. Adding a scope in Google Cloud alone does not update an existing authorization."
        case .workspacePolicy: return "Your Google Workspace domain policy blocks this app from accessing Gmail (HTTP 403; domainPolicy). Ask your administrator to allow this OAuth client and the gmail.send scope in Admin Console > Security > API controls."
        case .rateLimited: return "Gmail's API or sending limit was reached. Wait before trying again. The app will not resend automatically."
        case .rejected: return "Gmail rejected the message. Check the recipient, attachment, and your organization's mail policy. The app will not resend automatically."
        case .network: return "Could not connect to Gmail. Check your network connection. The app will not resend automatically."
        case .outcomeUnknown: return "The send result is unknown. Gmail may have accepted this message. Check Gmail Sent before sending again to avoid duplicates. The app will not resend automatically."
        }
    }
}

public struct GmailSendReceipt: Equatable, Sendable {
    public let messageID: String
    public init(messageID: String) { self.messageID = messageID }
}

public protocol MailSending: Sendable {
    func send(message: Data, accessToken: String) async throws -> GmailSendReceipt
}

public final class GmailService: MailSending {
    private let session: URLSession
    private let redirectDelegate = RejectMailRedirects()

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(message: Data, accessToken: String) async throws -> GmailSendReceipt {
        guard message.count <= MIMEMessageBuilder.maximumMessageBytes else { throw GmailError.messageTooLarge }
        guard !accessToken.isEmpty, !accessToken.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GmailError.authentication
        }
        try Task.checkCancellation()
        struct Payload: Encodable { let raw: String }
        let payload = try JSONEncoder().encode(Payload(raw: message.base64URL))
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        let data: Data
        let response: URLResponse
        do {
            // One request only. Never retry an ambiguous send or follow a redirect with mail data.
            (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                 .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw GmailError.network
            default: throw GmailError.outcomeUnknown
            }
        } catch { throw GmailError.outcomeUnknown }
        guard let response = response as? HTTPURLResponse else { throw GmailError.outcomeUnknown }
        switch response.statusCode {
        case 200..<300:
            struct Receipt: Decodable { let id: String }
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), !receipt.id.isEmpty else {
                throw GmailError.outcomeUnknown
            }
            return GmailSendReceipt(messageID: receipt.id)
        case 401: throw GmailError.authentication
        case 413: throw GmailError.messageTooLarge
        case 429: throw GmailError.rateLimited
        case 408, 500...599: throw GmailError.outcomeUnknown
        default:
            let failure = try? JSONDecoder().decode(APIError.self, from: data)
            let legacyReasons = failure?.error.errors?.compactMap(\.reason) ?? []
            let structuredReasons = failure?.error.details?
                .filter { $0.type == "type.googleapis.com/google.rpc.ErrorInfo" }
                .compactMap(\.reason) ?? []
            let reasons = Set(legacyReasons + structuredReasons)
            if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "quotaExceeded", "mailRateLimitExceeded"]) {
                throw GmailError.rateLimited
            }
            if reasons.contains("authError") { throw GmailError.authentication }
            if response.statusCode == 403 {
                if !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]) { throw GmailError.apiDisabled }
                if !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]) { throw GmailError.insufficientScope }
                if reasons.contains("domainPolicy") { throw GmailError.workspacePolicy }
                throw GmailError.permissionDenied
            }
            if !reasons.isDisjoint(with: ["messageTooBig", "messageTooLarge", "attachmentTooLarge"])
                || (response.statusCode == 400 && failure?.error.message?.lowercased().contains("message too large") == true) {
                throw GmailError.messageTooLarge
            }
            // Do not expose Google's message text; it can include recipients or other private data.
            throw GmailError.rejected
        }
    }

    private struct APIError: Decodable {
        struct Detail: Decodable {
            struct Reason: Decodable { let reason: String? }
            struct ErrorInfo: Decodable {
                let type: String?
                let reason: String?
                enum CodingKeys: String, CodingKey {
                    case type = "@type"
                    case reason
                }
            }
            let errors: [Reason]?
            let details: [ErrorInfo]?
            let message: String?
        }
        let error: Detail
    }
}

final class RejectMailRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
