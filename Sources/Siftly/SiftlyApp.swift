import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory to hide from Dock but allow UI
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SiftlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var configManager: ConfigManager
    @StateObject private var proxyManager: ProxyManager
    
    init() {
        let config = ConfigManager()
        _configManager = StateObject(wrappedValue: config)
        _proxyManager = StateObject(wrappedValue: ProxyManager(configManager: config))
    }
    
    var body: some Scene {
        MenuBarExtra("Siftly", systemImage: iconName) {
            SiftlyMenu(configManager: configManager, proxyManager: proxyManager)
        }
        
        Settings {
            SettingsView(configManager: configManager)
        }
    }
    
    var iconName: String {
        switch proxyManager.state {
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
