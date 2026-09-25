import AppKit
import Foundation

/// A browser found on this Mac and how the app can start it through the tunnel.
struct Browser: Identifiable, Hashable, Sendable {
    enum Family: Sendable {
        case chromium, gecko
        /// Listed but not usable: follows only the system-wide proxy (Safari).
        case systemProxyOnly
        /// Listed but not usable: ignores the launch options that carry the proxy rule (Arc).
        case ignoresOptions
    }

    var usable: Bool { family == .chromium || family == .gecko }

    var id: String { bundleID }
    let bundleID: String
    let name: String
    let appURL: URL
    let family: Family
    /// True once its launch through the tunnel has been seen to work on a real Mac.
    let tested: Bool

    /// The grey word next to it in the chooser.
    var how: String {
        switch family {
        case .chromium: "separate profile"
        case .gecko: "temporary profile"
        case .systemProxyOnly: "system proxy only"
        case .ignoresOptions: "ignores launch options"
        }
    }
}

/// Finds the browsers registered for http and starts them with the tunnel as their only proxy.
@MainActor
enum Browsers {
    /// Launch strategies by bundle identifier. Anything not listed here is left out of the chooser.
    static let families: [String: Browser.Family] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        // Arc is Chromium inside but ignored the URL, the profile and the proxy rule on 2026-09-25.
        "company.thebrowser.Browser": .ignoresOptions,
        "org.mozilla.firefox": .gecko,
        "org.mozilla.firefoxdeveloperedition": .gecko,
        "org.mozilla.nightly": .gecko,
        "com.apple.Safari": .systemProxyOnly,
        "com.apple.SafariTechnologyPreview": .systemProxyOnly,
    ]

    /// Launches that have been seen to reach the stick through the tunnel (see SPEC, External browsers).
    /// Chrome 153, Firefox 132 and Edge 154, 2026-09-25: the stick page loaded, and the box saw connections only to the stick.
    static let tested: Set<String> = ["com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac"]

    static func detect() -> [Browser] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "http://example.invalid/")!)
        var seen = Set<String>()
        var out: [Browser] = []
        for url in urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, let family = families[id], !seen.contains(id) else { continue }
            seen.insert(id)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            out.append(Browser(bundleID: id, name: name, appURL: url, family: family, tested: tested.contains(id)))
        }
        // Usable ones first, Safari and friends last.
        return out.sorted { ($0.usable ? 0 : 1) < ($1.usable ? 0 : 1) }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LTE Stick View", isDirectory: true)
    }

    /// Temporary Firefox profiles live here, one per launch, named with this prefix.
    static let geckoPrefix = "lte-stick-view-firefox-"

    /// A proxy auto-config script that sends only the stick's host through the tunnel.
    /// Everything else the browser does (updates, telemetry, other tabs) goes direct from the Mac,
    /// so none of it leaves through the box, whose internet in the field is the SIM.
    static func pac(host: String, socksPort: UInt16) -> String {
        """
        function FindProxyForURL(url, host) {
          if (host === "\(host)") return "SOCKS5 127.0.0.1:\(socksPort)";
          return "DIRECT";
        }
        """
    }

    static func launch(_ b: Browser, url: URL, socksPort: UInt16) {
        let host = url.host() ?? "192.168.8.1"
        let script = pac(host: host, socksPort: socksPort)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        switch b.family {
        case .chromium:
            let profile = supportDir.appendingPathComponent("profiles/\(b.bundleID)", isDirectory: true)
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            config.arguments = [
                "--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,\(Data(script.utf8).base64EncodedString())",
                "--user-data-dir=\(profile.path)",
                "--no-first-run",
                "--no-default-browser-check",
                url.absoluteString,
            ]
        case .gecko:
            let profile = FileManager.default.temporaryDirectory
                .appendingPathComponent(geckoPrefix + UUID().uuidString.prefix(8), isDirectory: true)
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let pacURL = "data:application/x-ns-proxy-autoconfig;base64," + Data(script.utf8).base64EncodedString()
            let prefs = [
                ("network.proxy.type", "2"),
                ("network.proxy.autoconfig_url", "\"\(pacURL)\""),
                ("browser.shell.checkDefaultBrowser", "false"),
                ("browser.aboutwelcome.enabled", "false"),
                ("browser.startup.homepage_override.mstone", "\"ignore\""),
                ("datareporting.policy.dataSubmissionPolicyBypassNotification", "true"),
                ("toolkit.telemetry.reportingpolicy.firstRun", "false"),
            ]
            let userJS = prefs.map { "user_pref(\"\($0.0)\", \($0.1));" }.joined(separator: "\n") + "\n"
            try? userJS.write(to: profile.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
            config.arguments = ["-profile", profile.path, "-no-remote", "-new-instance", url.absoluteString]
        case .systemProxyOnly, .ignoresOptions:
            return
        }
        Tunnel.shared.note("opening the stick page in \(b.name): " + (config.arguments.joined(separator: " ")))
        NSWorkspace.shared.openApplication(at: b.appURL, configuration: config) { _, error in
            guard let error else { return }
            let text = error.localizedDescription
            Task { @MainActor in Tunnel.shared.note("could not open \(b.name): \(text)") }
        }
    }

    /// Deletes temporary Firefox profiles that no running process uses any more.
    /// Called at launch and at quit, so a Firefox still open keeps its profile until the next launch.
    static func cleanTemporaryProfiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        let running = System.run("/bin/ps", ["-axo", "command="]).out
        for dir in items where dir.lastPathComponent.hasPrefix(geckoPrefix) {
            if running.contains(dir.lastPathComponent) { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
