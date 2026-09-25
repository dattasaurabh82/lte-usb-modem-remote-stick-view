import Darwin
import Foundation
import Observation

/// Owns the one ssh process and the four status lines.
@MainActor
@Observable
final class Tunnel {
    static let shared = Tunnel()

    var config = Config()
    var targetIndex: Int {
        didSet { UserDefaults.standard.set(targetIndex, forKey: "targetIndex") }
    }

    private(set) var route = Line(light: .hollow, word: "not tried")
    private(set) var ssh = Line(light: .hollow, word: "down")
    private(set) var socks = Line(light: .hollow, word: "off")
    private(set) var stick = Line(light: .hollow, word: "not checked")
    private(set) var connectedAt: Date?
    private(set) var log: [String] = []
    private(set) var command = ""

    /// True while ssh is starting or up; the Reconnect button shows when false.
    var isActive: Bool { process != nil }

    private var process: Process?
    private var stderrText = ""
    private var stopping = false
    private var stickLoop: Task<Void, Never>?
    private var generation = 0

    var target: Target { config.targets[min(targetIndex, config.targets.count - 1)] }

    private init() {
        targetIndex = UserDefaults.standard.integer(forKey: "targetIndex")
    }

    // MARK: start

    func start() {
        guard process == nil else { return }
        generation += 1
        let gen = generation
        stopping = false
        stderrText = ""
        connectedAt = nil
        let t = target
        let port = config.socksPort
        route = Line(light: .yellow, word: "trying", detail: t.host)
        ssh = Line(light: .yellow, word: "connecting", detail: t.userHost)
        socks = Line(light: .hollow, word: "off")
        stick = Line(light: .hollow, word: "not checked")

        Task {
            let leftover = await Task.detached { Orphan.endLeftover() }.value
            if let leftover { self.note(leftover) }

            let free = await Task.detached { System.portIsFree(port) }.value
            guard gen == self.generation else { return }
            if !free {
                let holder = await Task.detached { System.listenerName(port) }.value
                let who = holder.map { "by \($0)" } ?? ""
                self.socks = Line(light: .red, word: "port in use", detail: who)
                self.ssh = Line(light: .red, word: "failed", detail: "port in use")
                self.route = Line(light: .hollow, word: "not tried")
                self.note("port \(port) is already taken \(who)")
                return
            }
            self.launch(t, port: port, gen: gen)
        }
    }

    private func launch(_ t: Target, port: UInt16, gen: Int) {
        let args = [
            "-N", "-D", "127.0.0.1:\(port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "BatchMode=yes",
            t.userHost,
        ]
        command = (["/usr/bin/ssh"] + args).joined(separator: " ")
        note(command)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in Tunnel.shared.stderrArrived(text, gen: gen) }
        }
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in Tunnel.shared.exited(status: status, gen: gen) }
        }
        do {
            try p.run()
        } catch {
            ssh = Line(light: .red, word: "failed", detail: "could not start ssh")
            note("could not start /usr/bin/ssh: \(error.localizedDescription)")
            return
        }
        process = p
        Orphan.record(p.processIdentifier)

        Task { await self.waitForSocks(port: port, gen: gen) }
    }

    // MARK: readiness

    private func waitForSocks(port: UInt16, gen: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard gen == generation, process != nil else { return }
            if await Task.detached(operation: { System.canConnect(port) }).value {
                guard gen == generation else { return }
                connectedAt = Date()
                route = Line(light: .green, word: target.name, detail: target.host)
                ssh = Line(light: .green, word: "up", detail: target.userHost)
                socks = Line(light: .green, word: "127.0.0.1:\(port)")
                note("socks up on 127.0.0.1:\(port)")
                startStickLoop(gen: gen)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard gen == generation, process != nil else { return }
        note("socks port did not open within 10 s, stopping ssh")
        ssh = Line(light: .red, word: "failed", detail: "timed out")
        process?.terminate()
    }

    private func startStickLoop(gen: Int) {
        stickLoop?.cancel()
        stickLoop = Task {
            while !Task.isCancelled, gen == self.generation, self.process != nil {
                await self.checkStick(gen: gen)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func checkStick(gen: Int) async {
        let base = config.stickURL
        let port = config.socksPort
        if stick.light != .green { stick = Line(light: .yellow, word: "checking") }
        let name = await Stick.deviceName(base: base, socksPort: port)
        guard gen == generation, process != nil else { return }
        let host = base.host() ?? base.absoluteString
        if let name {
            if stick.light != .green { note("stick answered device/information (\(name))") }
            stick = Line(light: .green, word: "reachable", detail: "\(name) at \(host)")
        } else {
            if stick.light != .red { note("stick did not answer at \(host) through the tunnel") }
            stick = Line(light: .red, word: "no answer", detail: host)
        }
    }

    // MARK: ssh output and exit

    private func stderrArrived(_ text: String, gen: Int) {
        guard gen == generation else { return }
        stderrText += text
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            note(line.hasPrefix("ssh: ") ? line : "ssh: \(line)")
        }
    }

    private func exited(status: Int32, gen: Int) {
        guard gen == generation else { return }
        stickLoop?.cancel()
        process = nil
        connectedAt = nil
        Orphan.clear()
        socks = Line(light: .hollow, word: "off")
        stick = Line(light: .hollow, word: "not checked")
        if stopping {
            ssh = Line(light: .hollow, word: "down")
            route = Line(light: .hollow, word: "not tried")
            note("ssh stopped")
            return
        }
        let why = Self.reason(stderrText)
        note("ssh exited with status \(status): \(why)")
        if ssh.light != .red { ssh = Line(light: .red, word: "failed", detail: why) }
        if ["name not found", "timed out", "refused"].contains(why) {
            route = Line(light: .red, word: "no route", detail: "\(target.host): \(why)")
        } else {
            route = Line(light: .hollow, word: "not tried")
        }
    }

    /// Maps ssh's error text to one of the state words in SPEC.md.
    static func reason(_ stderr: String) -> String {
        let e = stderr.lowercased()
        if e.contains("remote host identification has changed") { return "host key changed" }
        if e.contains("host key verification failed") { return "host key unknown" }
        if e.contains("permission denied") { return "sign-in refused" }
        if e.contains("address already in use") || e.contains("cannot listen to port")
            || e.contains("could not request local forwarding") { return "port in use" }
        if e.contains("could not resolve hostname") { return "name not found" }
        if e.contains("timed out") { return "timed out" }
        if e.contains("connection refused") { return "refused" }
        return "exited"
    }

    // MARK: stop

    /// Stops ssh and waits up to 2 s before killing it. Used on reconnect and at quit.
    func stop() {
        generation += 1
        stopping = true
        stickLoop?.cancel()
        guard let p = process else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        connectedAt = nil
        Orphan.clear()
        ssh = Line(light: .hollow, word: "down")
        socks = Line(light: .hollow, word: "off")
        stick = Line(light: .hollow, word: "not checked")
        route = Line(light: .hollow, word: "not tried")
        note("ssh stopped")
    }

    func reconnect() {
        stop()
        start()
    }

    private func note(_ s: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        log.append("\(stamp) \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// Remembers the ssh process ID on disk so a crashed run can be cleaned up next time.
enum Orphan {
    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LTE Stick View", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh.pid")
    }

    static func record(_ pid: Int32) {
        try? "\(pid)\n".write(to: file, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Ends an ssh left behind by an earlier run, if the recorded one is still ours.
    static func endLeftover() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        defer { clear() }
        guard let cmd = System.commandLine(of: pid),
              cmd.hasPrefix("/usr/bin/ssh"), cmd.contains("-D 127.0.0.1:") else { return nil }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return "ended a leftover ssh (pid \(pid)) from an earlier run"
    }
}
