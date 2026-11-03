import DropToMailCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var googleAuth: GoogleAuthService
    @EnvironmentObject private var jobs: SendJobManager
    @State private var authenticationTask: Task<Void, Never>?
    @State private var isAuthenticating = false
    @AppStorage(AppSettings.countdownKey) private var waitSeconds = AppSettings.defaultCountdown
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section("Google Account") {
                LabeledContent("Account", value: googleAuth.account?.email ?? "Not connected")
                    .textSelection(.enabled)
                HStack {
                    Button(googleAuth.account == nil ? "Authenticate with Google" : "Change / Reauthenticate") {
                        isAuthenticating = true
                        authenticationTask = Task {
                            await googleAuth.authenticate()
                            isAuthenticating = false
                            authenticationTask = nil
                        }
                    }
                    .disabled(googleAuth.isBusy || isAuthenticating)
                    if isAuthenticating {
                        Button("Cancel") { authenticationTask?.cancel() }
                    } else if googleAuth.account != nil {
                        Button("Disconnect", role: .destructive) {
                            Task { await googleAuth.disconnect() }
                        }
                        .disabled(googleAuth.isBusy)
                    }
                    if googleAuth.isBusy { ProgressView().controlSize(.small) }
                }
                if let message = googleAuth.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(googleAuth.messageIsError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            .disabled(jobs.state.isBusy)

            Section("ZIP Password") {
                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    Button(isPasswordVisible ? "Hide" : "Show") {
                        isPasswordVisible.toggle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                }
                HStack {
                    Button("Save Password", action: savePassword)
                    Button("Remove", role: .destructive, action: removePassword)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }

            Section("Send Delay") {
                Slider(
                    value: Binding(
                        get: { Double(AppSettings.countdownValues.firstIndex(of: waitSeconds) ?? 2) },
                        set: { waitSeconds = AppSettings.countdownValues[Int($0.rounded())] }
                    ),
                    in: 0...4,
                    step: 1
                )
                LabeledContent("Delay", value: "\(waitSeconds) seconds")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .onDisappear { authenticationTask?.cancel() }
        .onAppear {
            if !AppSettings.countdownValues.contains(waitSeconds) {
                waitSeconds = AppSettings.defaultCountdown
            }
            loadPassword()
        }
    }

    private func loadPassword() {
        do {
            password = try KeychainService.readPassword() ?? ""
        } catch {
            report(error)
        }
    }

    private func savePassword() {
        do {
            if password.isEmpty {
                try KeychainService.deletePassword()
            } else {
                try KeychainService.savePassword(password)
            }
            statusIsError = false
            statusMessage = password.isEmpty ? "Password removed." : "Password saved in Keychain."
        } catch {
            report(error)
        }
    }

    private func removePassword() {
        do {
            try KeychainService.deletePassword()
            password = ""
            statusIsError = false
            statusMessage = "Password removed."
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        statusIsError = true
        statusMessage = error.localizedDescription
    }
}
