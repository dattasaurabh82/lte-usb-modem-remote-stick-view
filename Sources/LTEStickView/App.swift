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
/// Exit status 0 when all four are green.
@MainActor
enum SelfTest {
    static func run(route: String?) {
        let t = Tunnel.shared
        if let route {
            let key = route.lowercased()
            if let i = t.config.targets.firstIndex(where: { $0.name.lowercased().contains(key) || $0.userHost.lowercased() == key }) {
                t.targetIndex = i
            } else {
                print("no target matches \"\(route)\"; targets: " + t.config.targets.map(\.name).joined(separator: ", "))
                exit(2)
            }
        }
        Task { @MainActor in
            t.start()
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                let settled = t.stick.light == .green || t.stick.light == .red || t.ssh.light == .red
                if settled { break }
            }
            let lines = [("route", t.route), ("ssh session", t.ssh), ("socks proxy", t.socks), ("lte stick", t.stick)]
            for (name, l) in lines {
                print(name.padding(toLength: 13, withPad: " ", startingAt: 0)
                      + l.light.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                      + l.word + (l.detail.isEmpty ? "" : "  " + l.detail))
            }
            print("")
            print(t.log.joined(separator: "\n"))
            let ok = lines.allSatisfy { $0.1.light == .green }
            t.stop()
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }
}
