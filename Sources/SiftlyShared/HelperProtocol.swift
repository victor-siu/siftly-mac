import Foundation

// MARK: - Shared constants and protocol between Siftly app and SiftlyHelper daemon

public enum HelperConstants {
    public static let socketPath = "/var/run/siftly-helper.sock"
    public static let bundleIdentifier = "com.siftly.helper"
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.siftly.helper"
    public static let launchdPlistPath = "/Library/LaunchDaemons/com.siftly.helper.plist"
}

// MARK: - Request / Response

public struct HelperRequest: Codable {
    public let command: HelperCommand
    public var binaryPath: String?
    public var configPath: String?

    public init(command: HelperCommand, binaryPath: String? = nil, configPath: String? = nil) {
        self.command = command
        self.binaryPath = binaryPath
        self.configPath = configPath
    }
}

public enum HelperCommand: String, Codable {
    case start
    case stop
    case restart
    case status
}

public struct HelperResponse: Codable {
    public let success: Bool
    public var pid: Int32?
    public var running: Bool?
    public var message: String?

    public init(success: Bool, pid: Int32? = nil, running: Bool? = nil, message: String? = nil) {
        self.success = success
        self.pid = pid
        self.running = running
        self.message = message
    }

    public static func ok(pid: Int32? = nil, running: Bool? = nil) -> HelperResponse {
        HelperResponse(success: true, pid: pid, running: running)
    }

    public static func error(_ message: String) -> HelperResponse {
        HelperResponse(success: false, message: message)
    }
}
