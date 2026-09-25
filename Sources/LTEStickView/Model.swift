import Foundation

/// How a target signs in: over the tailnet (Tailscale SSH), with the Mac's key, or with a Keychain password.
enum SignIn: String, Codable, Sendable {
    case tailnet, key, password
}

/// One way to reach the box: a name for the switch and the ssh destination.
struct Target: Hashable, Codable, Sendable {
    var name: String
    var userHost: String
    var signIn: SignIn

    var host: String {
        userHost.split(separator: "@").last.map(String.init) ?? userHost
    }

    static let defaults: [Target] = [
        Target(name: "Home LAN", userHost: "root@orangepizero.lan", signIn: .key),
        Target(name: "Tailscale", userHost: "root@orangepizero", signIn: .tailnet),
    ]
}

/// Settings the tunnel needs, kept as JSON in the app's user defaults under "config".
/// Passwords are not in here; they live in the Keychain (see Keychain).
struct Config: Codable, Sendable, Equatable {
    var targets: [Target] = Target.defaults
    var stickURL: URL = URL(string: "http://192.168.8.1/")!
    var socksPort: UInt16 = 1080

    static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: "config"),
              let c = try? JSONDecoder().decode(Config.self, from: data), !c.targets.isEmpty else { return Config() }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "config") }
    }
}

/// Traffic-light state of one status line.
enum Light: String, Sendable {
    case green, yellow, red, hollow
}

/// One status line: the dot, the coloured state word, and the grey detail.
struct Line: Sendable, Equatable {
    var light: Light
    var word: String
    var detail: String = ""
}
