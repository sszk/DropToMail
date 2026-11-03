import Foundation
import Combine

public enum SendJobState: Equatable {
    case ready
    case preparing
    case countdown(Int)
    case sending
    case success
    case cancelled
    case outcomeUnknown
    case error(String)

    public var isBusy: Bool {
        switch self {
        case .preparing, .countdown, .sending: return true
        case .ready, .success, .cancelled, .outcomeUnknown, .error: return false
        }
    }
}

@MainActor
public final class SendJobManager: ObservableObject {
    @Published public private(set) var state: SendJobState = .ready
    @Published public private(set) var cleanupWarning: String?

    private let zipService: ZipService
    private let mailService: MailSending
    private var jobTask: Task<Void, Never>?
    private var preparationTask: Task<PreparedArchive, Error>?
    private var encodingTask: Task<Data, Error>?
    private var resetTask: Task<Void, Never>?
    private var activeJobID: UUID?

    public init(zipService: ZipService = ZipService(), mailService: MailSending = GmailService()) {
        self.zipService = zipService
        self.mailService = mailService
    }

    public func start(inputs: [URL], recipient: String, sender: String, password: String, waitSeconds: Int,
                      authorize: @escaping @MainActor () async throws -> String,
                      onAuthorizationFailure: @escaping @MainActor () -> Void = {}) {
        guard !state.isBusy else { return }
        resetTask?.cancel()
        cleanupWarning = nil
        guard AppSettings.isValidEmail(recipient), AppSettings.isValidEmail(sender) else {
            state = .error(GmailError.invalidAddress.localizedDescription)
            return
        }
        guard !password.isEmpty else {
            state = .error("Set a ZIP password in Settings.")
            return
        }
        guard AppSettings.countdownValues.contains(waitSeconds) else {
            state = .error("Choose a supported countdown duration.")
            return
        }

        let jobID = UUID()
        activeJobID = jobID
        state = waitSeconds == 0 ? .preparing : .countdown(waitSeconds)
        let zipService = self.zipService
        let mailService = self.mailService
        let preparation = Task.detached(priority: .userInitiated) {
            try zipService.createArchive(inputs: inputs, password: password)
        }
        preparationTask = preparation
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(waitSeconds))

        jobTask = Task { [weak self] in
            guard let self else { return }
            var result: SendJobState
            do {
                if waitSeconds > 0 {
                    while clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                        let duration = clock.now.duration(to: deadline).components
                        let seconds = duration.seconds + (duration.attoseconds > 0 ? 1 : 0)
                        self.state = .countdown(max(0, Int(seconds)))
                    }
                }
                self.state = .preparing
                let archive = try await preparation.value
                try Task.checkCancellation()
                let encoding = Task.detached(priority: .userInitiated) {
                    try MIMEMessageBuilder().build(archive: archive, sender: sender, recipient: recipient)
                }
                self.encodingTask = encoding
                let message = try await encoding.value
                try Task.checkCancellation()
                let token = try await authorize()
                try Task.checkCancellation()
                guard self.activeJobID == jobID else { throw CancellationError() }
                self.state = .sending
                // From this point cancel() is deliberately ineffective. A lost response can mean sent.
                _ = try await mailService.send(message: message, accessToken: token)
                result = .success
            } catch is CancellationError {
                result = self.state == .sending ? .outcomeUnknown : .cancelled
            } catch GmailError.outcomeUnknown {
                result = .outcomeUnknown
            } catch {
                if error as? GmailError == .authentication { onAuthorizationFailure() }
                result = .error(error.localizedDescription)
            }

            preparation.cancel()
            self.encodingTask?.cancel()
            _ = await self.encodingTask?.result
            // Await detached work before cleanup, including cancellation during ZIP preparation.
            switch await preparation.result {
            case .success(let archive):
                do { try zipService.cleanup(jobDirectory: archive.jobDirectory) }
                catch { self.cleanupWarning = "Temporary ZIP cleanup failed: \(error.localizedDescription)" }
            case .failure(let error):
                if result == .cancelled, !(error is CancellationError) {
                    result = .error(error.localizedDescription)
                }
            }
            guard self.activeJobID == jobID else { return }
            self.state = result
            self.activeJobID = nil
            self.preparationTask = nil
            self.encodingTask = nil
            self.jobTask = nil
            if result == .success || result == .cancelled {
                let terminalState = result
                self.resetTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(terminalState == .success ? 2 : 1)) } catch { return }
                    if self?.state == terminalState { self?.state = .ready }
                }
            }
        }
    }

    public func cancel() {
        switch state {
        case .countdown, .preparing:
            jobTask?.cancel()
            preparationTask?.cancel()
            encodingTask?.cancel()
        default: break
        }
    }
}
