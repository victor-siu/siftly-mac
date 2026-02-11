import Foundation
import Yams

// MARK: - DNS Profile

struct DNSProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var upstream: [String]
    var fallback: [String]
    var bootstrap: [String]
    
    init(id: UUID = UUID(), name: String, upstream: [String] = [], fallback: [String] = [], bootstrap: [String] = []) {
        self.id = id
        self.name = name
        self.upstream = upstream
        self.fallback = fallback
        self.bootstrap = bootstrap
    }
    
    var splitTunnelEntries: [SplitTunnelEntry] {
        get { upstream.compactMap { SplitTunnelEntry(fromString: $0) } }
        set {
            upstream = upstream.filter { !($0.hasPrefix("[/") && $0.contains("/]")) }
            upstream.append(contentsOf: newValue.map { $0.toString() })
        }
    }
    
    var defaultUpstreams: [String] {
        get { upstream.filter { !($0.hasPrefix("[/") && $0.contains("/]")) } }
        set {
            let splits = splitTunnelEntries
            upstream = newValue
            upstream.append(contentsOf: splits.map { $0.toString() })
        }
    }
}

// MARK: - Active Config (written to YAML for dnsproxy)

struct SiftlyConfig: Codable {
    var bootstrap: [String] = ["8.8.8.8:53"]
    var listenAddrs: [String] = ["127.0.0.1"]
    var listenPorts: [Int] = [5353]
    var upstream: [String] = ["1.1.1.1:53"]
    var fallback: [String] = []
    var timeout: String = "10s"
    var ratelimit: Int = 0
    var refuseAny: Bool = false
    var edns: Bool = false
    var http3: Bool = false
    var upstreamMode: String = ""
    var cache: Bool = false
    var cacheOptimistic: Bool = false
    var cacheSize: Int = 0
    var cacheMinTtl: Int = 0
    var cacheMaxTtl: Int = 0
    var maxGoRoutines: Int = 0
    var udpBufSize: Int = 0
    var tlsMinVersion: Decimal = 1.2
    var optimisticAnswerTtl: String = ""
    var optimisticMaxAge: String = ""
    
    enum CodingKeys: String, CodingKey {
        case bootstrap
        case listenAddrs = "listen-addrs"
        case listenPorts = "listen-ports"
        case upstream
        case fallback
        case timeout
        case ratelimit
        case refuseAny = "refuse-any"
        case edns
        case http3
        case upstreamMode = "upstream-mode"
        case cache
        case cacheOptimistic = "cache-optimistic"
        case cacheSize = "cache-size"
        case cacheMinTtl = "cache-min-ttl"
        case cacheMaxTtl = "cache-max-ttl"
        case maxGoRoutines = "max-go-routines"
        case udpBufSize = "udp-buf-size"
        case tlsMinVersion = "tls-min-version"
        case optimisticAnswerTtl = "optimistic-answer-ttl"
        case optimisticMaxAge = "optimistic-max-age"
    }
    
    var splitTunnelEntries: [SplitTunnelEntry] {
        get { upstream.compactMap { SplitTunnelEntry(fromString: $0) } }
        set {
            upstream = upstream.filter { !($0.hasPrefix("[/") && $0.contains("/]")) }
            upstream.append(contentsOf: newValue.map { $0.toString() })
        }
    }
    
    var defaultUpstreams: [String] {
        get { upstream.filter { !($0.hasPrefix("[/") && $0.contains("/]")) } }
        set {
            let splits = splitTunnelEntries
            upstream = newValue
            upstream.append(contentsOf: splits.map { $0.toString() })
        }
    }
    
    /// Apply a DNS profile's upstream/fallback/bootstrap settings
    mutating func apply(profile: DNSProfile) {
        upstream = profile.upstream
        fallback = profile.fallback
        bootstrap = profile.bootstrap
    }
}

// MARK: - Split Tunnel Entry

struct SplitTunnelEntry: Identifiable, Equatable {
    let id = UUID()
    var domain: String
    var server: String
    
    init(domain: String, server: String) {
        self.domain = domain
        self.server = server
    }
    
    init?(fromString string: String) {
        guard string.hasPrefix("[/"),
              let endBracketIndex = string.range(of: "/]")?.lowerBound else {
            return nil
        }
        let domainPart = string[string.index(string.startIndex, offsetBy: 2)..<endBracketIndex]
        let serverPart = string[string.index(endBracketIndex, offsetBy: 2)...]
        self.domain = String(domainPart)
        self.server = String(serverPart)
    }
    
    func toString() -> String {
        "[/\(domain)/]\(server)"
    }
}

// MARK: - App State (profiles + active profile, persisted separately from dnsproxy config)

struct AppState: Codable {
    var profiles: [DNSProfile] = []
    var activeProfileId: UUID?
}

// MARK: - Config Manager

class ConfigManager: ObservableObject {
    @Published var config: SiftlyConfig {
        didSet { saveConfig() }
    }
    @Published var appState: AppState {
        didSet { saveAppState() }
    }
    
    private let configPath: URL
    private let appStatePath: URL
    
    var activeProfile: DNSProfile? {
        guard let id = appState.activeProfileId else { return nil }
        return appState.profiles.first { $0.id == id }
    }
    
    init() {
        let fileManager = FileManager.default
        let configDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".siftly")
        self.configPath = configDir.appendingPathComponent("config.yaml")
        self.appStatePath = configDir.appendingPathComponent("profiles.json")
        
        if !fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        
        // Load dnsproxy config
        if let data = try? Data(contentsOf: configPath),
           let loaded = try? YAMLDecoder().decode(SiftlyConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = SiftlyConfig()
        }
        
        // Load app state (profiles)
        if let data = try? Data(contentsOf: appStatePath),
           let loaded = try? JSONDecoder().decode(AppState.self, from: data) {
            self.appState = loaded
        } else {
            self.appState = AppState(profiles: [
                DNSProfile(
                    name: "Home",
                    upstream: ["1.1.1.1:53"],
                    fallback: ["8.8.8.8:53"],
                    bootstrap: ["8.8.8.8:53"]
                ),
                DNSProfile(
                    name: "Work",
                    upstream: ["9.9.9.9:53"],
                    fallback: ["1.1.1.1:53"],
                    bootstrap: ["8.8.8.8:53"]
                )
            ])
        }
    }
    
    // MARK: - Persistence
    
    func saveConfig() {
        // Capture value on main thread, write on background thread (no data race)
        let configCopy = self.config
        let path = self.configPath
        DispatchQueue.global(qos: .background).async {
            if let yaml = try? YAMLEncoder().encode(configCopy) {
                try? yaml.write(to: path, atomically: true, encoding: .utf8)
            }
        }
    }
    
    private func saveAppState() {
        let stateCopy = self.appState
        let path = self.appStatePath
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(stateCopy) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }
    
    // MARK: - Profile Management
    
    func switchProfile(to id: UUID) {
        guard let profile = appState.profiles.first(where: { $0.id == id }) else { return }
        appState.activeProfileId = profile.id
        config.apply(profile: profile)
    }
    
    func addProfile(_ profile: DNSProfile) {
        appState.profiles.append(profile)
    }
    
    func deleteProfile(_ profile: DNSProfile) {
        appState.profiles.removeAll { $0.id == profile.id }
        if appState.activeProfileId == profile.id {
            appState.activeProfileId = nil
        }
    }
    
    func updateProfile(_ profile: DNSProfile) {
        if let index = appState.profiles.firstIndex(where: { $0.id == profile.id }) {
            appState.profiles[index] = profile
            if appState.activeProfileId == profile.id {
                config.apply(profile: profile)
            }
        }
    }
    
    /// Capture current DNS settings into a new profile
    func captureCurrentAsProfile(name: String) -> DNSProfile {
        DNSProfile(
            name: name,
            upstream: config.upstream,
            fallback: config.fallback,
            bootstrap: config.bootstrap
        )
    }
    
    // MARK: - Split Tunnel Helpers
    
    func setDefaultUpstream(_ server: String) {
        config.defaultUpstreams = [server]
    }
    
    func addSplitTunnel(domain: String, server: String) {
        var entries = config.splitTunnelEntries
        entries.append(SplitTunnelEntry(domain: domain, server: server))
        config.splitTunnelEntries = entries
    }
    
    func removeSplitTunnel(at offsets: IndexSet) {
        var entries = config.splitTunnelEntries
        entries.remove(atOffsets: offsets)
        config.splitTunnelEntries = entries
    }
}
