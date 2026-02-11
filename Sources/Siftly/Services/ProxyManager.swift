import Foundation
import Combine
import SiftlyShared

enum ProxyState: Equatable {
    case active
    case inactive
    case healing
    case error(String)
}

class ProxyManager: ObservableObject {
    @Published var state: ProxyState = .inactive
    @Published var helperInstalled: Bool = HelperClient.isAvailable
    private var process: Process?
    private var privilegedPID: Int32?
    private var configManager: ConfigManager
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    private var watchdogTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private let helperClient = HelperClient()
    
    // Path to dnsproxy binary.
    // In a real app bundle, this would be Bundle.main.url(forResource: "dnsproxy", withExtension: nil)
    // For this playground, we'll look in a few places.
    private var binaryPath: URL? {
        let fileManager = FileManager.default
        
        // 1. Check inside App Bundle (Contents/MacOS/dnsproxy)
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dnsproxy"),
           fileManager.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }
        
        // 2. Check development paths
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        
        let candidates = [
            cwd.appendingPathComponent("dnsproxy"),
            cwd.appendingPathComponent("../dnsproxy"),
            URL(fileURLWithPath: "/usr/local/bin/dnsproxy"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("go/bin/dnsproxy")
        ]
        
        // Return the standardized (absolute) path of the first existing candidate
        return candidates.first { fileManager.fileExists(atPath: $0.path) }?.standardizedFileURL
    }
    
    init(configManager: ConfigManager) {
        self.configManager = configManager
        checkDependency()
        setupConfigObservation()
    }
    
    private func setupConfigObservation() {
        configManager.$config
            .dropFirst() // Skip initial value
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.restartIfActive()
            }
            .store(in: &cancellables)
    }
    
    private func restartIfActive() {
        guard state == .active || state == .healing else { return }
        print("Configuration changed. Restarting proxy...")
        stop()
        let work = DispatchWorkItem { [weak self] in
            self?.start()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    
    private func checkDependency() {
        if binaryPath == nil {
            print("dnsproxy binary not found. Please build it or place it in the working directory.")
            // Placeholder: In a real scenario, we might download it here.
            state = .error("dnsproxy binary not found")
        }
    }
    
    func start() {
        guard let binaryURL = binaryPath else {
            state = .error("dnsproxy binary missing")
            return
        }
        
        if state == .active { return }
        
        state = .healing // Transition state
        
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siftly/config.yaml").path
            
        let needsRoot = configManager.config.listenPorts.contains { $0 < 1024 }
        
        if needsRoot {
            if HelperClient.isAvailable {
                startViaHelper(binaryPath: binaryURL.path, configPath: configPath)
            } else {
                startPrivilegedLegacy(binaryPath: binaryURL.path, configPath: configPath)
            }
        } else {
            startStandard(binaryURL: binaryURL, configPath: configPath)
        }
    }
    
    private func startStandard(binaryURL: URL, configPath: String) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--config-path", configPath, "--verbose"]
        
        // Redirect to /dev/null to avoid pipe buffer deadlock
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(proc.terminationStatus)
            }
        }
        
        do {
            try process.run()
            self.process = process
            self.state = .active
            self.restartAttempts = 0
            print("dnsproxy started with PID: \(process.processIdentifier)")
        } catch {
            state = .error("Failed to start: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helper Daemon (no password prompt)
    
    private func startViaHelper(binaryPath: String, configPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let response = try self.helperClient.start(binaryPath: binaryPath, configPath: configPath)
                DispatchQueue.main.async {
                    if response.success, let pid = response.pid {
                        self.privilegedPID = pid
                        self.state = .active
                        self.restartAttempts = 0
                        self.helperInstalled = true
                        print("dnsproxy started via helper with PID: \(pid)")
                        self.startWatchdogViaHelper()
                    } else {
                        self.state = .error(response.message ?? "Helper start failed")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }
    
    private func stopViaHelper() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.helperClient.stop()
        }
        privilegedPID = nil
    }
    
    private func startWatchdogViaHelper() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let response = try? self.helperClient.status() else {
                    return // Helper unreachable — don't take action, might be transient
                }
                if response.running != true {
                    DispatchQueue.main.async {
                        self.watchdogTimer?.invalidate()
                        self.watchdogTimer = nil
                        self.privilegedPID = nil
                        self.handleTermination(1)
                    }
                }
            }
        }
    }
    
    // MARK: - Legacy osascript fallback (password prompt each time)
    
    private func startPrivilegedLegacy(binaryPath: String, configPath: String) {
        let command = "'\(binaryPath)' --config-path '\(configPath)' --verbose > /dev/null 2>&1 & echo $!"
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
        
        print("Attempting privileged start...")
        
        // Run osascript on background thread to avoid blocking UI during password prompt
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if process.terminationStatus == 0, let pid = Int32(output) {
                        self.privilegedPID = pid
                        self.state = .active
                        self.restartAttempts = 0
                        print("dnsproxy started (privileged) with PID: \(pid)")
                        self.startWatchdog(pid: pid)
                    } else {
                        print("osascript failed: \(output)")
                        self.state = .error("Privileged start failed: \(output)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .error("Failed to run osascript: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func startWatchdog(pid: Int32) {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Check if process exists on a background thread to avoid blocking UI
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/ps")
                task.arguments = ["-p", String(pid)]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    
                    if task.terminationStatus != 0 {
                        DispatchQueue.main.async {
                            self.watchdogTimer?.invalidate()
                            self.watchdogTimer = nil
                            self.privilegedPID = nil
                            self.handleTermination(1)
                        }
                    }
                } catch {
                    print("Watchdog failed: \(error)")
                }
            }
        }
    }
    
    func stop() {
        // Cancel any pending restart
        pendingRestart?.cancel()
        pendingRestart = nil
        
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        
        if let process = process {
            process.terminationHandler = nil
            process.terminate()
            self.process = nil
        }
        
        if privilegedPID != nil {
            if HelperClient.isAvailable {
                stopViaHelper()
            } else {
                // Legacy: kill via osascript
                let script = "do shell script \"kill \(privilegedPID!)\" with administrator privileges"
                NSAppleScript(source: script)?.executeAndReturnError(nil)
                self.privilegedPID = nil
            }
        }
        
        restartAttempts = 0
        state = .inactive
    }
    
    private func handleTermination(_ status: Int32) {
        print("dnsproxy terminated with status: \(status)")
        
        if status != 0 {
            // Auto-healing logic
            if restartAttempts < maxRestartAttempts {
                state = .healing
                restartAttempts += 1
                let delay = Double(restartAttempts) * 2.0 // Exponential backoff
                print("Restarting in \(delay) seconds...")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.start()
                }
            } else {
                state = .error("Crashing repeatedly. Stopped.")
            }
        } else {
            state = .inactive
        }
    }
}
