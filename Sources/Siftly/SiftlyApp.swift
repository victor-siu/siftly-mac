import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SiftlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var configManager = ConfigManager()
    @State private var proxyManager: ProxyManager?

    var body: some Scene {
        MenuBarExtra("Siftly", systemImage: iconName) {
            SiftlyMenu(configManager: configManager, proxyManager: proxyManager!)
        }

        Settings {
            SettingsView(configManager: configManager)
        }
    }

    init() {
        let config = ConfigManager()
        _configManager = State(initialValue: config)
        _proxyManager = State(initialValue: ProxyManager(configManager: config))
    }

    private var iconName: String {
        guard let pm = proxyManager else { return "shield.slash" }
        switch pm.state {
        case .active:
            return "shield.fill"
        case .inactive:
            return "shield.slash"
        case .healing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.shield.fill"
        }
    }
}
