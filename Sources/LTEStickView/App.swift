import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        // Started by ssh as its askpass program: answer and exit, nothing else.
        if ProcessInfo.processInfo.environment[Askpass.flag] == "1" { Askpass.runHelper() }
        let args = CommandLine.arguments
        if args.contains("--version") {
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
            exit(0)
        }
        if args.contains("--askpass-test") { AskpassTest.run() }
        if let i = args.firstIndex(of: "--simulate") {
            let what = args.dropFirst(i + 1).first ?? ""
            guard Tailscale.simulations.contains(what) else {
                print("--simulate takes one of: " + Tailscale.simulations.joined(separator: ", "))
                exit(2)
            }
            Tailscale.simulated = what
        }
        if let i = args.firstIndex(of: "--self-test") {
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

        // One window per "Open stick page" in the built-in viewer; the value only keeps them apart.
        WindowGroup("Stick page", id: "viewer", for: Int.self) { _ in
            ViewerWindow(tunnel: Tunnel.shared)
        }
        .defaultSize(width: 1320, height: 860)

        Settings {
            SettingsView(tunnel: Tunnel.shared)
        }
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
        MainActor.assumeIsolated { Browsers.cleanTemporaryProfiles() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Tunnel.shared.stop()
            Browsers.cleanTemporaryProfiles()
        }
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
            if CommandLine.arguments.contains("--detect") {
                let (url, report) = await t.detectStick()
                print("detect from box: \(report)" + (url.map { ", stick address \($0.absoluteString)" } ?? ""))
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
            // Once the stick answers, wait for a Tailscale reading taken after connect (the path word), at most 6 s.
            let learned = (t.tailscaleReadAt ?? .distantPast) > (t.connectedAt ?? .distantFuture)
                || Date().timeIntervalSince(started) > 6
            if t.stick.light == .green && learned { break }
            if t.stick.light == .red || t.ssh.light == .red || t.retryAt != nil { break }
        }
    }

    private static func allGreen(_ t: Tunnel) -> Bool {
        [t.route, t.ssh, t.socks, t.stick].allSatisfy { $0.light == .green } && t.tailscale.light != .red
    }

    private static func snapshot(_ t: Tunnel, title: String?) -> String {
        let lines = [("route", t.route), ("tailscale", t.tailscale), ("ssh session", t.ssh),
                     ("socks proxy", t.socks), ("lte stick", t.stick)]
        var out = title.map { "[\($0)]\n" } ?? ""
        for (name, l) in lines {
            out += name.padding(toLength: 13, withPad: " ", startingAt: 0)
                + l.light.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                + l.word + (l.detail.isEmpty ? "" : "  " + l.detail) + "\n"
        }
        if let fix = t.tailscaleFix { out += "             button: \(fix.label)\n" }
        return out
    }
}

/// Headless check of the password chain, link by link, without a real password login:
/// Keychain round trip, helper answering a password prompt through the one-time socket,
/// helper declining a host key question, a wrong token, the socket answering only once,
/// and ssh itself starting this binary as its askpass program.
@MainActor
enum AskpassTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        let exe = Bundle.main.executableURL!.path

        // 1. Keychain
        let account = "lsv-selftest@example.invalid"
        check(Keychain.set("first", for: account), "keychain: save")
        check(Keychain.set("second", for: account), "keychain: update")
        check(Keychain.password(for: account) == "second", "keychain: read back the updated value")
        check(Keychain.delete(account), "keychain: delete")
        check(Keychain.password(for: account) == nil, "keychain: gone after delete")

        // 2. Helper answers a password prompt, once
        func helper(_ prompt: String, env: [String: String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = [prompt]
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        let server = Askpass.Server(password: "s3cret with spaces")
        check(server.start(), "socket: started at \(server.path)")
        let perms = (try? FileManager.default.attributesOfItem(atPath: server.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o600, "socket: readable by this user only (\(String(perms, radix: 8)))")
        let host = helper("Are you sure you want to continue connecting (yes/no/[fingerprint])?", env: server.environment)
        check(host.0 != 0 && host.1.isEmpty, "helper: declines a host key question")
        var wrong = server.environment
        wrong[Askpass.tokenVar] = "not-the-token"
        let bad = helper("root@box's password: ", env: wrong)
        check(bad.0 != 0 && bad.1.isEmpty, "helper: a wrong token gets nothing")
        let good = helper("root@box's password: ", env: server.environment)
        check(good.0 == 0 && good.1 == "s3cret with spaces", "helper: answers a password prompt through the socket")
        let again = helper("root@box's password: ", env: server.environment)
        check(again.0 != 0 && again.1.isEmpty, "socket: answers only once")
        check(!FileManager.default.fileExists(atPath: server.path), "socket: removed after answering")
        server.stop()

        // 3. ssh really starts this binary as its askpass program
        let trace = "/tmp/lsv-askpass-trace-\(getpid()).txt"
        let s2 = Askpass.Server(password: "unused")
        _ = s2.start()
        var env = s2.environment
        env[Askpass.traceVar] = trace
        let target = Tunnel.shared.config.targets.first { $0.signIn == .tailnet }?.userHost ?? "root@localhost"
        let r = System.run("/usr/bin/ssh", ["-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask",
                                            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=8",
                                            target, "true"], env: env)
        let asked = (try? String(contentsOfFile: trace, encoding: .utf8)) ?? ""
        check(asked.contains("asked:") && r.status != 0,
              "ssh: started the helper by itself (\(asked.split(separator: "\n").first.map { String($0.prefix(70)) } ?? "no prompt")), and stopped when it declined")
        s2.stop()
        try? FileManager.default.removeItem(atPath: trace)

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
