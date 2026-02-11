import Foundation
import SystemConfiguration
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

// MARK: - Security Validation

/// Verify that the binary path points to a dnsproxy executable inside a Siftly.app bundle.
/// Allowed pattern: /Applications/Siftly.app/Contents/MacOS/dnsproxy
///                  or user-relocated bundles like ~/Applications/Siftly.app/Contents/MacOS/dnsproxy
private func isAllowedBinary(_ path: String) -> Bool {
    let resolved = (path as NSString).resolvingSymlinksInPath
    // Must end with the expected bundle-relative path
    guard resolved.hasSuffix("/Siftly.app/Contents/MacOS/dnsproxy") else {
        log("Rejected binary path (not in app bundle): \(resolved)")
        return false
    }
    // Must actually exist and be executable
    return FileManager.default.isExecutableFile(atPath: resolved)
}

/// Verify that the config path is under a user's Application Support/Siftly directory.
/// Allowed pattern: /Users/<username>/Library/Application Support/Siftly/<file>
private func isAllowedConfigPath(_ path: String) -> Bool {
    let resolved = (path as NSString).resolvingSymlinksInPath
    let pattern = #"^/Users/[a-zA-Z0-9._-]+/Library/Application Support/Siftly/.+$"#
    guard resolved.range(of: pattern, options: .regularExpression) != nil else {
        log("Rejected config path (not in Application Support): \(resolved)")
        return false
    }
    // Reject path traversal
    guard !resolved.contains("..") else {
        log("Rejected config path (contains ..): \(resolved)")
        return false
    }
    return FileManager.default.fileExists(atPath: resolved)
}

/// Get the UID of the peer connected to a Unix domain socket.
private func getPeerUID(fd: Int32) -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else {
        return nil
    }
    return uid
}

/// Returns the UID of the console (GUI-logged-in) user, or nil.
private func consoleUserUID() -> uid_t? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) else {
        return nil
    }
    _ = name // consume the CFString
    return uid
}

// MARK: - Socket Server

final class SocketServer: @unchecked Sendable {
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

        // Restrict socket to owner (root) only. We verify the connecting
        // client's UID via getpeereid() in handleClient() to ensure only
        // the console user can issue commands.
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
        // Verify the connecting process belongs to the console user (not root, not other users)
        guard let peerUID = getPeerUID(fd: fd) else {
            log("Rejected connection: could not determine peer UID")
            return
        }
        guard let consoleUID = consoleUserUID(), peerUID == consoleUID else {
            log("Rejected connection: peer UID \(peerUID) is not the console user")
            return
        }

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

            // Security: only allow dnsproxy from inside the Siftly.app bundle
            guard isAllowedBinary(binaryPath) else {
                return .error("Rejected: binary must be inside Siftly.app bundle")
            }
            // Security: only allow config from Application Support/Siftly
            guard isAllowedConfigPath(configPath) else {
                return .error("Rejected: config must be in ~/Library/Application Support/Siftly/")
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

            // Security: same validation as start
            guard isAllowedBinary(binaryPath) else {
                return .error("Rejected: binary must be inside Siftly.app bundle")
            }
            guard isAllowedConfigPath(configPath) else {
                return .error("Rejected: config must be in ~/Library/Application Support/Siftly/")
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
