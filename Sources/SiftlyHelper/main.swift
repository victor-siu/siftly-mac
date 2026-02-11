import Foundation
import SiftlyShared

/// SiftlyHelper — A privileged daemon that manages the dnsproxy process.
///
/// Runs as root via a LaunchDaemon. Listens on a Unix domain socket for
/// JSON commands from the unprivileged Siftly app. This avoids the need
/// for password prompts on every start/stop.

// MARK: - Process Manager

final class DNSProxyManager {
    private var process: Process?
    private var currentPID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    var isRunning: Bool { process?.isRunning == true }
    var pid: Int32? { currentPID }

    func start(binaryPath: String, configPath: String) throws -> Int32 {
        // Stop any existing instance first
        if isRunning { stop() }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--config-path", configPath, "--verbose"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        self.process = proc
        log("dnsproxy started with PID \(proc.processIdentifier)")
        return proc.processIdentifier
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        let pid = proc.processIdentifier
        proc.terminate()

        // Give it 3 seconds to exit gracefully, then force kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning {
                proc.interrupt()
                log("Force-killed dnsproxy PID \(pid)")
            }
        }
        proc.waitUntilExit()
        self.process = nil
        log("dnsproxy PID \(pid) stopped")
    }
}

// MARK: - Socket Server

final class SocketServer {
    private let socketPath: String
    private let proxyManager = DNSProxyManager()
    private var serverSocket: Int32 = -1
    private var running = true

    init(socketPath: String = HelperConstants.socketPath) {
        self.socketPath = socketPath
    }

    func start() {
        // Remove stale socket
        unlink(socketPath)

        // Create Unix domain socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            log("Failed to create socket: \(String(cString: strerror(errno)))")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path into sun_path
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            log("Socket path too long")
            exit(1)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                guard bind(serverSocket, sockPtr, addrLen) == 0 else {
                    log("Failed to bind socket: \(String(cString: strerror(errno)))")
                    exit(1)
                }
            }
        }

        // Set permissions: owner (root) + group + user can connect
        // 0o666 allows any local user to connect — acceptable since this is a
        // single-user desktop app. For multi-user systems, restrict to a specific group.
        chmod(socketPath, 0o666)

        guard listen(serverSocket, 5) == 0 else {
            log("Failed to listen on socket: \(String(cString: strerror(errno)))")
            exit(1)
        }

        log("SiftlyHelper listening on \(socketPath)")

        // Install signal handlers for graceful shutdown
        signal(SIGTERM) { _ in
            log("Received SIGTERM, shutting down...")
            exit(0)
        }
        signal(SIGINT) { _ in
            log("Received SIGINT, shutting down...")
            exit(0)
        }

        // Clean up on exit
        atexit {
            unlink(HelperConstants.socketPath)
        }

        // Accept loop
        while running {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &clientLen)
                }
            }

            if clientFd < 0 {
                if errno == EINTR { continue }
                log("Accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Handle each connection in its own thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: clientFd)
                close(clientFd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        // Read up to 8KB of data
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])
        let response: HelperResponse

        do {
            let request = try JSONDecoder().decode(HelperRequest.self, from: data)
            response = handleRequest(request)
        } catch {
            response = .error("Invalid request: \(error.localizedDescription)")
        }

        // Send response
        if let responseData = try? JSONEncoder().encode(response) {
            _ = responseData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, responseData.count)
            }
        }
    }

    private func handleRequest(_ request: HelperRequest) -> HelperResponse {
        log("Received command: \(request.command.rawValue)")

        switch request.command {
        case .start:
            guard let binaryPath = request.binaryPath,
                  let configPath = request.configPath else {
                return .error("start requires binaryPath and configPath")
            }

            // Validate paths exist
            guard FileManager.default.fileExists(atPath: binaryPath) else {
                return .error("Binary not found: \(binaryPath)")
            }
            guard FileManager.default.fileExists(atPath: configPath) else {
                return .error("Config not found: \(configPath)")
            }

            do {
                let pid = try proxyManager.start(binaryPath: binaryPath, configPath: configPath)
                return .ok(pid: pid, running: true)
            } catch {
                return .error("Failed to start: \(error.localizedDescription)")
            }

        case .stop:
            proxyManager.stop()
            return .ok(running: false)

        case .restart:
            guard let binaryPath = request.binaryPath,
                  let configPath = request.configPath else {
                return .error("restart requires binaryPath and configPath")
            }
            proxyManager.stop()
            do {
                let pid = try proxyManager.start(binaryPath: binaryPath, configPath: configPath)
                return .ok(pid: pid, running: true)
            } catch {
                return .error("Failed to restart: \(error.localizedDescription)")
            }

        case .status:
            return .ok(pid: proxyManager.pid, running: proxyManager.isRunning)
        }
    }

    func shutdown() {
        running = false
        proxyManager.stop()
        close(serverSocket)
        unlink(socketPath)
    }
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] SiftlyHelper: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - Main

log("SiftlyHelper starting (pid: \(ProcessInfo.processInfo.processIdentifier), uid: \(getuid()))")
let server = SocketServer()
server.start()
