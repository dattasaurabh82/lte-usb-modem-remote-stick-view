import Foundation

/// How a target signs in. Password mode arrives in step 6.
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

/// Settings the tunnel needs. Editable settings arrive in step 6.
struct Config: Sendable {
    var targets: [Target] = Target.defaults
    var stickURL: URL = URL(string: "http://192.168.8.1/")!
    var socksPort: UInt16 = 1080
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
