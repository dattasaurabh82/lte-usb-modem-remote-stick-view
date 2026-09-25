import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--self-test") {
            let rest = CommandLine.arguments.dropFirst(i + 1).first
            SelfTest.run(route: rest)
        } else {
            LTEStickViewApp.main()
        }
    }
}

struct LTEStickViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("LTE Stick View", id: "main") {
            ContentView(tunnel: Tunnel.shared)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Turns a plain `kill` (SIGTERM) into a normal quit, so ssh is still stopped.
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Tunnel.shared.stop() }
    }
}

/// Headless check: connect, wait for the chain, print the four lines, disconnect.
/// With --drop, it then kills the ssh process to fake a lost link and waits for the reconnect.
/// Exit status 0 when all four are green at the end.
@MainActor
enum SelfTest {
    static func run(route: String?) {
        let t = Tunnel.shared
        let drop = CommandLine.arguments.contains("--drop")
        if let route, !route.hasPrefix("--") {
            let key = route.lowercased()
            if key == Tunnel.auto {
                t.choice = Tunnel.auto
            } else if let hit = t.config.targets.first(where: { $0.name.lowercased().contains(key) || $0.userHost.lowercased() == key }) {
                t.choice = hit.name
            } else {
                print("no target matches \"\(route)\"; use auto or one of: " + t.config.targets.map(\.name).joined(separator: ", "))
                exit(2)
            }
        }
        Task { @MainActor in
            t.start()
            await settle(t, within: 25)
            var ok = allGreen(t)
            if drop && ok, let pid = t.sshPID {
                print(snapshot(t, title: "before the drop"))
                t.note("self-test: killing ssh (pid \(pid)) to fake a lost link")
                kill(pid, SIGKILL)
                try? await Task.sleep(for: .seconds(1))
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                    if t.isActive && t.stick.light == .green { break }
                }
                await settle(t, within: 8)
                ok = allGreen(t)
                print(snapshot(t, title: "after the reconnect"))
            } else {
                print(snapshot(t, title: nil))
            }
            print(t.log.joined(separator: "\n"))
            t.stop()
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    private static func settle(_ t: Tunnel, within seconds: Double) async {
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .milliseconds(250))
            // Once the stick answers, give the route line up to 6 s to learn the Tailscale path.
            let learned = t.route.detail.contains("peer") || Date().timeIntervalSince(started) > 6
            if t.stick.light == .green && learned { break }
            if t.stick.light == .red || t.ssh.light == .red || t.retryAt != nil { break }
        }
    }

    private static func allGreen(_ t: Tunnel) -> Bool {
        [t.route, t.ssh, t.socks, t.stick].allSatisfy { $0.light == .green }
    }

    private static func snapshot(_ t: Tunnel, title: String?) -> String {
        let lines = [("route", t.route), ("ssh session", t.ssh), ("socks proxy", t.socks), ("lte stick", t.stick)]
        var out = title.map { "[\($0)]\n" } ?? ""
        for (name, l) in lines {
            out += name.padding(toLength: 13, withPad: " ", startingAt: 0)
                + l.light.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                + l.word + (l.detail.isEmpty ? "" : "  " + l.detail) + "\n"
        }
        return out
    }
}
