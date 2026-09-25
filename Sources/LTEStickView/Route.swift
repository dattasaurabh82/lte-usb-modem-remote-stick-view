import AppKit
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

/// Everything the tailscale line can say, from "not on this Mac" to "peer online".
enum TailscaleState: Sendable, Equatable {
    /// Neither the app nor a CLI is on this Mac.
    case notInstalled
    /// The app is there but its CLI did not answer.
    case unreadable
    /// The CLI answered with a backend state other than Running: Stopped, NeedsLogin, Starting and so on.
    case notRunning(String)
    /// Running, but the host is not a peer on this tailnet.
    case notAPeer
    case peer(PeerState)
}

/// Finds Tailscale on this Mac and reads `tailscale status --json`.
enum Tailscale {
    /// Bundle identifiers: the Mac App Store build, then the standalone build.
    static let bundleIDs = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]
    static let downloadURL = URL(string: "https://tailscale.com/download/mac")!

    /// Where the CLI can live. The app bundle's binary needs TAILSCALE_BE_CLI=1.
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// Set by --simulate: tailscale-missing, tailscale-stopped, tailscale-signed-out, tailscale-no-peer.
    nonisolated(unsafe) static var simulated: String?
    static let simulations = ["tailscale-missing", "tailscale-stopped", "tailscale-signed-out", "tailscale-no-peer"]

    /// The Tailscale app, found by bundle identifier wherever it is installed.
    static var appURL: URL? {
        if simulated == "tailscale-missing" { return nil }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// The CLI: inside the app bundle found above first, then the usual paths.
    static var cliPath: String? {
        if simulated == "tailscale-missing" { return nil }
        if let app = appURL {
            let inside = app.appendingPathComponent("Contents/MacOS/Tailscale").path
            if FileManager.default.isExecutableFile(atPath: inside) { return inside }
        }
        return cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func state(for host: String) -> TailscaleState {
        switch simulated {
        case "tailscale-missing": return .notInstalled
        case "tailscale-stopped": return .notRunning("Stopped")
        case "tailscale-signed-out": return .notRunning("NeedsLogin")
        case "tailscale-no-peer": return .notAPeer
        default: break
        }
        guard let cli = cliPath else { return appURL == nil ? .notInstalled : .unreadable }
        let r = System.run(cli, ["status", "--json"], env: ["TAILSCALE_BE_CLI": "1"])
        guard let data = r.out.data(using: .utf8),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return .unreadable }
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

    /// Readable word for a backend state.
    static func word(forBackend s: String) -> String {
        switch s {
        case "Stopped": "stopped"
        case "NeedsLogin", "NeedsMachineAuth": "signed out"
        case "Starting": "starting"
        case "NoState": "not started"
        default: s.lowercased()
        }
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
