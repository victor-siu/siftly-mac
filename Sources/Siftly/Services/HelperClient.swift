import Foundation
import SiftlyShared

/// Client for communicating with the SiftlyHelper privileged daemon
/// over a Unix domain socket.
final class HelperClient: Sendable {

    /// Whether the helper daemon is installed and its socket is reachable.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.socketPath)
    }

    // MARK: - Public API

    func start(binaryPath: String, configPath: String) throws -> HelperResponse {
        let request = HelperRequest(
            command: .start,
            binaryPath: binaryPath,
            configPath: configPath
        )
        return try send(request)
    }

    func stop() throws -> HelperResponse {
        try send(HelperRequest(command: .stop))
    }

    func restart(binaryPath: String, configPath: String) throws -> HelperResponse {
        let request = HelperRequest(
            command: .restart,
            binaryPath: binaryPath,
            configPath: configPath
        )
        return try send(request)
    }

    func status() throws -> HelperResponse {
        try send(HelperRequest(command: .status))
    }

    // MARK: - Socket Communication

    private func send(_ request: HelperRequest) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.socketCreationFailed(errno: errno)
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = HelperConstants.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw HelperError.connectionFailed(errno: errno)
        }

        let requestData = try JSONEncoder().encode(request)
        let written = requestData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, requestData.count)
        }
        guard written == requestData.count else {
            throw HelperError.writeFailed(errno: errno)
        }

        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        guard !responseData.isEmpty else {
            throw HelperError.emptyResponse
        }

        return try JSONDecoder().decode(HelperResponse.self, from: responseData)
    }
}

// MARK: - Errors

enum HelperError: LocalizedError, Sendable {
    case socketCreationFailed(errno: Int32)
    case connectionFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case emptyResponse
    case helperNotInstalled

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e):
            return "Socket creation failed: \(String(cString: strerror(e)))"
        case .connectionFailed(let e):
            return "Cannot connect to helper daemon: \(String(cString: strerror(e))). Run the install script first."
        case .writeFailed(let e):
            return "Failed to send request: \(String(cString: strerror(e)))"
        case .emptyResponse:
            return "Empty response from helper daemon"
        case .helperNotInstalled:
            return "Helper daemon is not installed. Run: sudo ./scripts/install_helper.sh"
        }
    }
}
