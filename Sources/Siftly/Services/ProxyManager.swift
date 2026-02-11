import Foundation
import Observation
import SiftlyShared

enum ProxyState: Equatable, Sendable {
    case active
    case inactive
    case healing
    case error(String)
}

@MainActor
@Observable
final class ProxyManager {
    var state: ProxyState = .inactive
    var helperInstalled: Bool = HelperClient.isAvailable

    private var process: Process?
    private var privilegedPID: Int32?
    private var configManager: ConfigManager
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    private var watchdogTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private let helperClient = HelperClient()

    // Config observation for auto-restart
    private var observationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    private var binaryPath: URL? {
        let fileManager = FileManager.default

        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dnsproxy"),
           fileManager.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("dnsproxy"),
            cwd.appendingPathComponent("../dnsproxy"),
            URL(fileURLWithPath: "/usr/local/bin/dnsproxy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/dnsproxy"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("go/bin/dnsproxy")
        ]

        return candidates.first { fileManager.fileExists(atPath: $0.path) }?.standardizedFileURL
    }

    init(configManager: ConfigManager) {
        self.configManager = configManager
        checkDependency()
        startConfigObservation()
    }

    // MARK: - Config Observation (replaces Combine)

    private func startConfigObservation() {
        observationTask = Task { [weak self] in
            var lastConfig: SiftlyConfig? = nil
            while !Task.isCancelled {
                guard let self else { return }
                let currentConfig = self.configManager.config
                if let last = lastConfig, last != currentConfig {
                    self.debouncedRestart()
                }
                lastConfig = currentConfig
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func debouncedRestart() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.restartIfActive()
        }
    }

    private func restartIfActive() {
        guard state == .active || state == .healing else { return }
        print("Configuration changed. Restarting proxy...")
        stop()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.start()
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func checkDependency() {
        if binaryPath == nil {
            print("dnsproxy binary not found.")
            state = .error("dnsproxy binary not found")
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard let binaryURL = binaryPath else {
            state = .error("dnsproxy binary missing")
            return
        }

        if state == .active { return }
        state = .healing

        let configPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Siftly/config.yaml").path

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
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--config-path", configPath, "--verbose"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status)
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.state = .active
            self.restartAttempts = 0
            print("dnsproxy started with PID: \(proc.processIdentifier)")
        } catch {
            state = .error("Failed to start: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Daemon (no password prompt)

    private func startViaHelper(binaryPath: String, configPath: String) {
        let client = self.helperClient
        Task {
            let result = await Self.performHelperStart(client: client, binaryPath: binaryPath, configPath: configPath)
            switch result {
            case .success(let response):
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
            case .failure(let error):
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private nonisolated static func performHelperStart(client: HelperClient, binaryPath: String, configPath: String) async -> Result<HelperResponse, Error> {
        do {
            let response = try client.start(binaryPath: binaryPath, configPath: configPath)
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func stopViaHelper() {
        let client = self.helperClient
        Task.detached {
            _ = try? client.stop()
        }
        privilegedPID = nil
    }

    private func startWatchdogViaHelper() {
        watchdogTimer?.invalidate()
        let client = self.helperClient
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                let running = await Self.checkHelperStatus(client: client)
                if running != true {
                    self?.watchdogTimer?.invalidate()
                    self?.watchdogTimer = nil
                    self?.privilegedPID = nil
                    self?.handleTermination(1)
                }
            }
        }
    }

    private nonisolated static func checkHelperStatus(client: HelperClient) async -> Bool? {
        guard let response = try? client.status() else { return nil }
        return response.running
    }

    // MARK: - Legacy osascript fallback

    private func startPrivilegedLegacy(binaryPath: String, configPath: String) {
        let command = "'\(binaryPath)' --config-path '\(configPath)' --verbose > /dev/null 2>&1 & echo $!"
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"

        print("Attempting privileged start...")

        Task {
            let result = await Self.runOsascript(script: script)
            switch result {
            case .success(let output):
                if let pid = Int32(output) {
                    self.privilegedPID = pid
                    self.state = .active
                    self.restartAttempts = 0
                    print("dnsproxy started (privileged) with PID: \(pid)")
                    self.startWatchdog(pid: pid)
                } else {
                    self.state = .error("Privileged start failed: \(output)")
                }
            case .failure(let error):
                self.state = .error("Failed to run osascript: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func runOsascript(script: String) async -> Result<String, Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus == 0 {
                return .success(output)
            } else {
                return .success("") // empty string signals failure to caller
            }
        } catch {
            return .failure(error)
        }
    }

    private func startWatchdog(pid: Int32) {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                let alive = await Self.isProcessAlive(pid: pid)
                if !alive {
                    self?.watchdogTimer?.invalidate()
                    self?.watchdogTimer = nil
                    self?.privilegedPID = nil
                    self?.handleTermination(1)
                }
            }
        }
    }

    private nonisolated static func isProcessAlive(pid: Int32) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        debounceTask?.cancel()
        debounceTask = nil

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
            if restartAttempts < maxRestartAttempts {
                state = .healing
                restartAttempts += 1
                let delay = Double(restartAttempts) * 2.0
                print("Restarting in \(delay) seconds...")

                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
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
