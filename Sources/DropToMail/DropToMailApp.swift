import DropToMailCore
import SwiftUI

@main
struct DropToMailApp: App {
    @StateObject private var googleAuth = GoogleAuthService()
    @StateObject private var jobs = SendJobManager()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(googleAuth)
                .environmentObject(jobs)
                .task { await googleAuth.restoreSession() }
        }
        .defaultSize(width: 320, height: 240)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(googleAuth)
                .environmentObject(jobs)
        }
    }
}
