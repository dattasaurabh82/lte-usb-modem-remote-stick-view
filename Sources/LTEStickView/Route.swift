import Foundation
import Network

/// Answer of a port-22 probe.
enum ProbeResult: Sendable, Equatable {
    case open
    case closed(String)

    var isOpen: Bool { self == .open }
    var why: String {
        switch self {
        case .open: "open"
        case .closed(let w): w
        }
    }
}

/// Resolves a host and opens a plain TCP connection to it, giving up after the timeout.
enum Probe {
    static func tcp(host: String, port: UInt16 = 22, timeout: Double = 1.5) async -> ProbeResult {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<ProbeResult, Never>) in
            let finish: @Sendable (ProbeResult) -> Void = { r in
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: r)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.open)
                case .failed(let e), .waiting(let e): finish(.closed(describe(e)))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.closed("no answer")) }
        }
    }

    private static func describe(_ e: NWError) -> String {
        switch e {
        case .dns: return "name not found"
        case .posix(let code) where code == .ECONNREFUSED: return "refused"
        case .posix(let code) where code == .ETIMEDOUT: return "no answer"
        default: return "no answer"
        }
    }
}

/// A flag that lets exactly one caller through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// What Tailscale knows about the peer behind a target.
struct PeerState: Sendable, Equatable {
    enum Path: Sendable, Equatable { case direct, relayed(String), idle }
    var online: Bool
    var path: Path
}

enum TailscaleState: Sendable, Equatable {
    case peer(PeerState)
    case notAPeer
    case notRunning(String)
    case unknown
}

/// Reads `tailscale status --json` and finds the peer that matches a host name or address.
enum Tailscale {
    /// Where the CLI can live, in the order tried. The app bundle's binary needs TAILSCALE_BE_CLI=1.
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static var cliPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func state(for host: String) -> TailscaleState {
        guard let cli = cliPath else { return .unknown }
        let r = System.run(cli, ["status", "--json"], env: ["TAILSCALE_BE_CLI": "1"])
        guard r.status == 0, let data = r.out.data(using: .utf8),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return .unknown }
        guard status.BackendState == "Running" else { return .notRunning(status.BackendState) }
        let h = host.lowercased()
        let match = (status.Peer ?? [:]).values.first { p in
            let dns = (p.DNSName ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let short = dns.split(separator: ".").first.map(String.init) ?? ""
            return dns == h || (!h.contains(".") && short == h) || (p.TailscaleIPs ?? []).contains(h)
        }
        guard let p = match else { return .notAPeer }
        let path: PeerState.Path
        if let cur = p.CurAddr, !cur.isEmpty {
            path = .direct
        } else if let pr = p.PeerRelay, !pr.isEmpty {
            path = .relayed("peer relay")
        } else if p.Active == true {
            path = .relayed(p.Relay ?? "DERP")
        } else {
            path = .idle
        }
        return .peer(PeerState(online: p.Online ?? false, path: path))
    }

    private struct Status: Decodable {
        var BackendState: String
        var Peer: [String: Peer]?
    }

    private struct Peer: Decodable {
        var DNSName: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var Active: Bool?
        var CurAddr: String?
        var Relay: String?
        var PeerRelay: String?
    }
}
