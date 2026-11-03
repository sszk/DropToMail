import AppKit
import DropToMailCore
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var googleAuth: GoogleAuthService
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppSettings.recipientKey) private var recipient = ""
    @AppStorage(AppSettings.floatingWindowKey) private var isFloating = false
    @AppStorage(AppSettings.countdownKey) private var waitSeconds = AppSettings.defaultCountdown
    @EnvironmentObject private var jobs: SendJobManager
    @State private var isTargeted = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(.tint)
                Text("DropToMail")
                    .font(.headline)
                Spacer()
                Button {
                    isFloating.toggle()
                } label: {
                    Image(systemName: isFloating ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .help(isFloating ? "Turn off always on top" : "Keep window on top")
                .accessibilityLabel(isFloating ? "Turn off always on top" : "Keep window on top")
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            TextField("Recipient email", text: $recipient)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .accessibilityLabel("Recipient email")
                .disabled(jobs.state.isBusy)

            DropTargetView(isTargeted: $isTargeted) { urls in
                handleDrop(urls)
            }
            .overlay {
                dropStateContent
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4]))
            }
            .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityStatus)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(WindowConfiguration(isFloating: isFloating))
        .onAppear {
            guard !jobs.state.isBusy else { return }
            do {
                try ZipService().cleanupAbandonedJobs()
            } catch {
                alertMessage = "Could not clean up temporary files: \(error.localizedDescription)"
            }
        }
        .onDisappear { jobs.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in jobs.cancel() }
        .onChange(of: jobs.cleanupWarning) { _, warning in
            if let warning { alertMessage = warning }
        }
        .onChange(of: jobs.state) { _, state in
            if case .error(let message) = state {
                alertMessage = message
            } else if state == .outcomeUnknown {
                alertMessage = GmailError.outcomeUnknown.localizedDescription
            }
        }
        .alert("DropToMail", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var dropStateContent: some View {
        switch jobs.state {
        case .ready:
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
        case .error(let message):
            resultDetails(icon: "exclamationmark.triangle", label: "Send failed", message: message, color: .red)
        case .outcomeUnknown:
            resultDetails(icon: "questionmark.circle", label: "Send result unknown",
                          message: GmailError.outcomeUnknown.localizedDescription, color: .orange)
        case .preparing:
            ProgressView("Preparing message…")
                .controlSize(.small)
        case .countdown(let seconds):
            Button {
                jobs.cancel()
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: countdownProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(seconds)")
                            .font(.system(size: 42, weight: .light, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                    .frame(width: 76, height: 76)
                    Text("Click to cancel")
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to cancel")
            .accessibilityLabel("Cancel send, \(seconds) seconds remaining")
        case .sending:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Sending")
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
                .accessibilityLabel("Gmail accepted the message. Delivery is not confirmed.")
                .help("Gmail accepted the message. Delivery is not confirmed.")
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancelled")
        }
    }

    private func resultDetails(icon: String, label: String, message: String, color: Color) -> some View {
        Button { alertMessage = message } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 36, weight: .light))
                Text(label).font(.caption)
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel("\(label). Show details.")
    }

    private var countdownProgress: Double {
        guard waitSeconds > 0, case .countdown(let remaining) = jobs.state else { return 0 }
        return Double(remaining) / Double(waitSeconds)
    }

    private var accessibilityStatus: String {
        switch jobs.state {
        case .ready: "Drop files to create a password-protected ZIP."
        case .preparing: "Preparing message."
        case .countdown(let seconds): "Sending in \(seconds) seconds. Click to cancel."
        case .sending: "Sending."
        case .success: "Gmail accepted the message. Delivery is not confirmed."
        case .outcomeUnknown: GmailError.outcomeUnknown.localizedDescription
        case .cancelled: "Cancelled."
        case .error: "An error occurred."
        }
    }

    private func handleDrop(_ urls: [URL]) {
        guard !jobs.state.isBusy else { return }
        guard let account = googleAuth.account else {
            alertMessage = "Authenticate with Google in Settings before dropping files."
            return
        }
        guard !googleAuth.isBusy else {
            alertMessage = "Wait for the Google account operation to finish."
            return
        }
        do {
            let password = try KeychainService.readPassword() ?? ""
            jobs.start(
                inputs: urls,
                recipient: recipient,
                sender: account.email,
                password: password,
                waitSeconds: waitSeconds,
                authorize: {
                    guard googleAuth.account?.subject == account.subject else {
                        throw GoogleAuthError.reauthenticationRequired
                    }
                    let token = try await googleAuth.accessToken()
                    guard googleAuth.account == account else { throw GoogleAuthError.reauthenticationRequired }
                    return token
                },
                onAuthorizationFailure: { googleAuth.invalidateAccessToken() }
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

private struct DropTargetView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onChange = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onChange = { isTargeted = $0 }
        nsView.onDrop = onDrop
    }
}

private final class DropView: NSView {
    var onChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDropTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDropTypes()
    }

    private func registerForDropTypes() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onChange?(false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { $0 as? URL } ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

private struct WindowConfiguration: NSViewRepresentable {
    let isFloating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        window?.level = isFloating ? .floating : .normal
        window?.setFrameAutosaveName("DropToMail.MainWindow")
    }
}
