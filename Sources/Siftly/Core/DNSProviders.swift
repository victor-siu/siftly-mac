import Foundation

struct DNSProvider: Identifiable {
    let id = UUID()
    let name: String
    let variants: [(protocol: String, address: String)]
}

extension DNSProvider: @unchecked Sendable {}

let commonDNSProviders: [DNSProvider] = [
    DNSProvider(name: "Google", variants: [
        ("Standard", "8.8.8.8"),
        ("DoT", "tls://dns.google"),
        ("DoH", "https://dns.google/dns-query")
    ]),
    DNSProvider(name: "Cloudflare", variants: [
        ("Standard", "1.1.1.1"),
        ("DoT", "tls://1.1.1.1"),
        ("DoH", "https://cloudflare-dns.com/dns-query")
    ]),
    DNSProvider(name: "AdGuard", variants: [
        ("Standard", "94.140.14.14"),
        ("DoT", "tls://dns.adguard.com"),
        ("DoH", "https://dns.adguard.com/dns-query"),
        ("DoQ", "quic://dns.adguard.com")
    ]),
    DNSProvider(name: "Quad9", variants: [
        ("Standard", "9.9.9.9"),
        ("DoT", "tls://dns.quad9.net"),
        ("DoH", "https://dns.quad9.net/dns-query")
    ]),
    DNSProvider(name: "OpenDNS", variants: [
        ("Standard", "208.67.222.222"),
        ("DoH", "https://doh.opendns.com/dns-query")
    ])
]
