import SwiftUI

struct SiftlyMenu: View {
    var configManager: ConfigManager
    var proxyManager: ProxyManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Status
        Button("Status: \(statusText)") { }
            .disabled(true)

        Divider()

        // Start / Stop
        if proxyManager.state == .inactive || isError {
            Button("▶ Start Proxy") {
                proxyManager.start()
            }
        } else {
            Button("■ Stop Proxy") {
                proxyManager.stop()
            }
        }

        Divider()

        // Profile quick-switch
        if !configManager.appState.profiles.isEmpty {
            ForEach(configManager.appState.profiles) { profile in
                Button {
                    configManager.switchProfile(to: profile.id)
                } label: {
                    let isCurrent = profile.id == configManager.appState.activeProfileId
                    Text("\(isCurrent ? "✓ " : "   ")\(profile.name)")
                }
            }

            Divider()
        }

        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            proxyManager.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    private var statusText: String {
        switch proxyManager.state {
        case .active:          return "Active"
        case .inactive:        return "Stopped"
        case .healing:         return "Restarting…"
        case .error(let msg):  return "Error: \(msg)"
        }
    }

    private var isError: Bool {
        if case .error = proxyManager.state { return true }
        return false
    }
}
