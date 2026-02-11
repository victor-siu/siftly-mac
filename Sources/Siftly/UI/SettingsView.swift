import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var configManager: ConfigManager
    @State private var newDomain: String = ""
    @State private var newServer: String = ""
    @State private var launchAtLogin: Bool = false
    
    // Default Upstream State
    @State private var defaultUpstream: String = ""
    @State private var defaultUpstreamError: String?
    
    // Validation State
    @State private var domainError: String?
    @State private var serverError: String?
    
    // Profile editing state
    @State private var editingProfile: DNSProfile?
    @State private var isAddingProfile: Bool = false
    @State private var profileName: String = ""
    @State private var profileUpstream: String = ""
    @State private var profileFallback: String = ""
    @State private var profileBootstrap: String = ""
    
    var body: some View {
        TabView {
            profilesTab
                .tabItem {
                    Label("Profiles", systemImage: "person.2")
                }
            
            dnsRulesTab
                .tabItem {
                    Label("DNS Rules", systemImage: "network")
                }
            
            serversTab
                .tabItem {
                    Label("Servers", systemImage: "server.rack")
                }
            
            networkTab
                .tabItem {
                    Label("Network", systemImage: "wifi")
                }
            
            cacheTab
                .tabItem {
                    Label("Cache", systemImage: "memorychip")
                }
            
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 700, height: 600)
        .padding()
        .onAppear {
            checkLaunchAtLogin()
            if let firstDefault = configManager.config.defaultUpstreams.first {
                defaultUpstream = firstDefault
            }
        }
    }
    
    // MARK: - Profiles Tab
    
    var profilesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DNS Profiles")
                    .font(.headline)
                Spacer()
                Button("Save Current as Profile") {
                    let profile = configManager.captureCurrentAsProfile(name: "New Profile")
                    editingProfile = profile
                    profileName = profile.name
                    profileUpstream = profile.upstream.joined(separator: "\n")
                    profileFallback = profile.fallback.joined(separator: "\n")
                    profileBootstrap = profile.bootstrap.joined(separator: "\n")
                    isAddingProfile = true
                }
                Button {
                    let profile = DNSProfile(name: "Untitled Profile")
                    editingProfile = profile
                    profileName = profile.name
                    profileUpstream = ""
                    profileFallback = ""
                    profileBootstrap = ""
                    isAddingProfile = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            
            List {
                ForEach(configManager.appState.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile.name)
                                    .fontWeight(.medium)
                                if profile.id == configManager.appState.activeProfileId {
                                    Text("Active")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            Text(profile.upstream.prefix(2).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Button("Activate") {
                            configManager.switchProfile(to: profile.id)
                        }
                        .disabled(profile.id == configManager.appState.activeProfileId)
                        
                        Button {
                            editingProfile = profile
                            profileName = profile.name
                            profileUpstream = profile.upstream.joined(separator: "\n")
                            profileFallback = profile.fallback.joined(separator: "\n")
                            profileBootstrap = profile.bootstrap.joined(separator: "\n")
                            isAddingProfile = false
                        } label: {
                            Image(systemName: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            configManager.deleteProfile(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered)
        }
        .padding()
        .sheet(item: $editingProfile) { profile in
            profileEditorSheet(profile: profile, isNew: isAddingProfile)
        }
    }
    
    private func profileEditorSheet(profile: DNSProfile, isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Profile" : "Edit Profile")
                .font(.title2)
                .fontWeight(.bold)
            
            TextField("Profile Name", text: $profileName)
                .textFieldStyle(.roundedBorder)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Upstream Servers")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextEditor(text: $profileUpstream)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text("One server per line")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Fallback Servers")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextEditor(text: $profileFallback)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Bootstrap Servers")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextEditor(text: $profileBootstrap)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel") {
                    editingProfile = nil
                }
                .keyboardShortcut(.cancelAction)
                
                Button(isNew ? "Add" : "Save") {
                    var updated = profile
                    updated.name = profileName
                    updated.upstream = profileUpstream.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    updated.fallback = profileFallback.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    updated.bootstrap = profileBootstrap.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    
                    if isNew {
                        configManager.addProfile(updated)
                    } else {
                        configManager.updateProfile(updated)
                    }
                    editingProfile = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profileName.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 520)
    }
    
    // MARK: - Servers Tab
    
    var serversTab: some View {
        Form {
            Section(header: Text("Bootstrap DNS")) {
                Text("DNS servers used to resolve IP addresses of upstream resolvers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                DNSListEditor(list: $configManager.config.bootstrap)
                    .frame(height: 120)
            }
            
            Section(header: Text("Fallback DNS")) {
                Text("Used if all upstreams fail.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                DNSListEditor(list: $configManager.config.fallback)
                    .frame(height: 120)
            }
            
            Section(header: Text("Upstream Mode")) {
                Picker("Mode", selection: $configManager.config.upstreamMode) {
                    Text("Load Balance").tag("")
                    Text("Parallel").tag("parallel")
                    Text("Fastest").tag("fastest")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
    
    var networkTab: some View {
        Form {
            Section(header: Text("Listening")) {
                VStack(alignment: .leading) {
                    Text("Listen Addresses")
                    StringListEditor(list: $configManager.config.listenAddrs)
                        .frame(height: 80)
                }
                
                VStack(alignment: .leading) {
                    Text("Listen Ports")
                    IntListEditor(list: $configManager.config.listenPorts)
                        .frame(height: 40)
                    Text("Ports below 1024 will prompt for admin password.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section(header: Text("Security & Protocols")) {
                TextField("Rate Limit (req/sec)", value: $configManager.config.ratelimit, formatter: NumberFormatter())
                Toggle("Refuse ANY Requests", isOn: $configManager.config.refuseAny)
                Toggle("Enable EDNS", isOn: $configManager.config.edns)
                Toggle("Enable HTTP/3", isOn: $configManager.config.http3)
                Picker("Min TLS Version", selection: $configManager.config.tlsMinVersion) {
                    Text("TLS 1.0").tag(Decimal(1.0))
                    Text("TLS 1.1").tag(Decimal(1.1))
                    Text("TLS 1.2").tag(Decimal(1.2))
                    Text("TLS 1.3").tag(Decimal(1.3))
                }
            }
        }
        .formStyle(.grouped)
    }
    
    var cacheTab: some View {
        Form {
            Section(header: Text("Caching")) {
                Toggle("Enable Cache", isOn: $configManager.config.cache)
                
                if configManager.config.cache {
                    Toggle("Optimistic Caching", isOn: $configManager.config.cacheOptimistic)
                    
                    TextField("Cache Size (entries)", value: $configManager.config.cacheSize, formatter: NumberFormatter())
                    
                    HStack {
                        TextField("Min TTL", value: $configManager.config.cacheMinTtl, formatter: NumberFormatter())
                        TextField("Max TTL", value: $configManager.config.cacheMaxTtl, formatter: NumberFormatter())
                    }
                    
                    if configManager.config.cacheOptimistic {
                        TextField("Optimistic Answer TTL", text: $configManager.config.optimisticAnswerTtl)
                        TextField("Optimistic Max Age", text: $configManager.config.optimisticMaxAge)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    var dnsRulesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Default Upstream Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Default Upstream")
                    .font(.headline)
                Text("Used when no specific rule matches a domain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ServerInputView(
                    text: $defaultUpstream,
                    error: defaultUpstreamError,
                    placeholder: "8.8.8.8",
                    providers: commonDNSProviders,
                    onValidate: { validateServer($0, errorState: &defaultUpstreamError) },
                    onCommit: {
                        if defaultUpstreamError == nil && !defaultUpstream.isEmpty {
                            configManager.setDefaultUpstream(defaultUpstream)
                        }
                    }
                )
            }
            
            Divider()
            
            // Split Tunneling Section
            VStack(alignment: .leading) {
                Text("Split Tunneling Rules")
                    .font(.headline)
                    .padding(.bottom, 5)
                
                List {
                    ForEach(configManager.config.splitTunnelEntries) { entry in
                        HStack {
                            Text(entry.domain)
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(entry.server)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete(perform: deleteEntry)
                }
                .listStyle(.bordered)
                
                // Add New Rule
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add New Rule")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Domain", text: $newDomain, prompt: Text("example.com"))
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: newDomain) { _, newValue in validateDomain(newValue) }
                            
                            if let error = domainError {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Supports wildcards (*.example.com)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(minWidth: 200)
                        
                        ServerInputView(
                            text: $newServer,
                            error: serverError,
                            placeholder: "8.8.8.8",
                            providers: commonDNSProviders,
                            onValidate: { validateServer($0, errorState: &serverError) }
                        )
                        .frame(minWidth: 200)
                        
                        Button(action: addEntry) {
                            Image(systemName: "plus")
                                .frame(height: 12)
                        }
                        .disabled(!isValidInput)
                        .padding(.top, 3)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        }
        .padding()
    }
    
    var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(enabled: newValue)
                    }
            } header: {
                Text("System")
            }
            
            Section {
                LabeledContent("Config Path") {
                    Text("~/.siftly/config.yaml")
                        .textSelection(.enabled)
                }
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
    }
    
    func addEntry() {
        configManager.addSplitTunnel(domain: newDomain, server: newServer)
        newDomain = ""
        newServer = ""
        domainError = nil
        serverError = nil
    }
    
    func deleteEntry(at offsets: IndexSet) {
        configManager.removeSplitTunnel(at: offsets)
    }
    
    // MARK: - Validation
    
    var isValidInput: Bool {
        !newDomain.isEmpty && !newServer.isEmpty && domainError == nil && serverError == nil
    }
    
    func validateDomain(_ domain: String) {
        if domain.isEmpty {
            domainError = nil
            return
        }
        
        let domainRegex = "^(?:\\*\\.)?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$"
        let predicate = NSPredicate(format: "SELF MATCHES %@", domainRegex)
        
        if !predicate.evaluate(with: domain) {
            domainError = "Invalid domain format"
        } else {
            domainError = nil
        }
    }
    
    func validateServer(_ server: String, errorState: inout String?) {
        if server.isEmpty {
            errorState = nil
            return
        }
        
        let ipv4Regex = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(:\\d+)?$"
        let ipv6Regex = "^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
        let urlRegex = "^(https?|tls|quic|sdns|h3)://.*$"
        
        let parts = server.split(separator: " ")
        for part in parts {
            let s = String(part)
            let isIP = NSPredicate(format: "SELF MATCHES %@", ipv4Regex).evaluate(with: s)
            let isIPv6 = NSPredicate(format: "SELF MATCHES %@", ipv6Regex).evaluate(with: s)
            let isURL = NSPredicate(format: "SELF MATCHES %@", urlRegex).evaluate(with: s)
            
            if !isIP && !isIPv6 && !isURL {
                errorState = "Invalid server address: \(s)"
                return
            }
        }
        
        errorState = nil
    }
    
    func checkLaunchAtLogin() {
        let service = SMAppService.mainApp
        launchAtLogin = (service.status == .enabled)
    }
    
    func toggleLaunchAtLogin(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return }
                try service.register()
            } else {
                if service.status == .notRegistered { return }
                try service.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
            checkLaunchAtLogin()
        }
    }
}
