import AppKit
import Foundation
import Network

public struct GoogleAuthorizationCode {
    public let code: String
    public let redirectURI: URL
}

@MainActor
public protocol GoogleAuthorizationBrowser {
    func authorize(configuration: GoogleOAuthConfiguration, request: OAuthAuthorizationRequest) async throws -> GoogleAuthorizationCode
}

/// A one-shot, IPv4 loopback-only receiver. It never listens on LAN interfaces.
@MainActor
public final class LoopbackGoogleAuthorizationBrowser: GoogleAuthorizationBrowser {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<GoogleAuthorizationCode, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private let openBrowser: (URL) -> Bool
    private let timeoutDuration: Duration

    public init(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, timeout: Duration = .seconds(180)) {
        self.openBrowser = openBrowser
        self.timeoutDuration = timeout
    }

    public func authorize(configuration: GoogleOAuthConfiguration, request: OAuthAuthorizationRequest) async throws -> GoogleAuthorizationCode {
        guard continuation == nil else { throw GoogleAuthError.busy }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.listener === listener, self.continuation != nil else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port,
                                      let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                                    self.finish(.failure(GoogleAuthError.listenerFailed))
                                    return
                                }
                                listener.newConnectionHandler = { [weak self] connection in
                                    Task { @MainActor in self?.accept(connection, request: request, redirect: redirect) }
                                }
                                if !self.openBrowser(request.authorizationURL(configuration: configuration, redirectURI: redirect)) {
                                    self.finish(.failure(GoogleAuthError.browserUnavailable))
                                }
                            case .failed: self.finish(.failure(GoogleAuthError.listenerFailed))
                            default: break
                            }
                        }
                    }
                    // Set a handler before start; replace it with the callback-aware handler when ready.
                    listener.newConnectionHandler = { $0.cancel() }
                    listener.start(queue: .main)
                    timeout = Task { [weak self, timeoutDuration] in
                        do { try await Task.sleep(for: timeoutDuration) } catch { return }
                        self?.finish(.failure(GoogleAuthError.timedOut))
                    }
                } catch { finish(.failure(GoogleAuthError.listenerFailed)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func accept(_ connection: NWConnection, request: OAuthAuthorizationRequest, redirect: URL) {
        guard continuation != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data(), request: request, redirect: redirect)
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data, request: OAuthAuthorizationRequest, redirect: URL) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { connection.cancel(); return }
                var buffer = buffer
                buffer.append(data ?? Data())
                guard error == nil, buffer.count <= 16384 else { self.close(id); return }
                guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { self.close(id) }
                    else { self.receive(connection, id: id, buffer: buffer, request: request, redirect: redirect) }
                    return
                }
                let line = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")[0]
                let parts = line.split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/?"),
                      let callback = URL(string: String(redirect.absoluteString.dropLast()) + String(parts[1])) else {
                    self.respond(connection, id: id, status: "400 Bad Request", message: "Invalid callback.")
                    return
                }
                do {
                    let code = try request.authorizationCode(from: callback, redirectURI: redirect)
                    self.respond(connection, id: id, status: "200 OK", message: "Authorization received. You can return to DropToMail.")
                    self.finish(.success(GoogleAuthorizationCode(code: code, redirectURI: redirect)))
                } catch GoogleAuthError.denied {
                    self.respond(connection, id: id, status: "200 OK", message: "Authorization declined. You can return to DropToMail.")
                    self.finish(.failure(GoogleAuthError.denied))
                } catch {
                    // Unrelated/malicious requests must not consume the pending authorization.
                    self.respond(connection, id: id, status: "400 Bad Request", message: "Invalid callback.")
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, message: String) {
        connections[id] = nil
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(message)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func finish(_ result: Result<GoogleAuthorizationCode, Error>) {
        let pending = continuation
        continuation = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        timeout?.cancel()
        timeout = nil
        pending?.resume(with: result)
    }
}
