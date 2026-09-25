import Darwin
import Foundation
import Network
import Observation

/// Owns the one ssh process and the four status lines.
@MainActor
@Observable
final class Tunnel {
    static let shared = Tunnel()
    static let auto = "auto"

    var config = Config()

    /// "auto" or a target's name. Remembered between launches.
    var choice: String {
        didSet { UserDefaults.standard.set(choice, forKey: "route") }
    }

    private(set) var route = Line(light: .hollow, word: "not tried")
    private(set) var ssh = Line(light: .hollow, word: "down")
    private(set) var socks = Line(light: .hollow, word: "off")
    private(set) var stick = Line(light: .hollow, word: "not checked")
    private(set) var connectedAt: Date?
    private(set) var retryAt: Date?
    private(set) var attempt = 0
    private(set) var log: [String] = []

    /// True while ssh is starting or up; the Reconnect button shows when false.
    var isActive: Bool { process != nil }
    var sshPID: Int32? { process?.processIdentifier }

    private var process: Process?
    private var active: Target?
    private var skipped: [String] = []
    /// nil until Tailscale has been asked for this session.
    private var peer: TailscaleState?
    private var stderrText = ""
    private var forcedReason: String?
    private var stopping = false
    private var wantsConnection = false
    private var lastFailureRetryable = false
    private var stickLoop: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private let monitor = NWPathMonitor()
    private var sawFirstPath = false
    private var netDebounce: Task<Void, Never>?

    private init() {
        choice = UserDefaults.standard.string(forKey: "route") ?? Tunnel.auto
        if choice != Tunnel.auto && !config.targets.contains(where: { $0.name == choice }) {
            choice = Tunnel.auto
        }
        monitor.pathUpdateHandler = { path in
            let summary = Tunnel.describe(path)
            Task { @MainActor in Tunnel.shared.networkChanged(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "lte-stick-view.path"))
    }

    // MARK: start

    func start() {
        guard process == nil else { return }
        generation += 1
        let gen = generation
        retryTask?.cancel()
        retryAt = nil
        stopping = false
        wantsConnection = true
        stderrText = ""
        forcedReason = nil
        connectedAt = nil
        active = nil
        skipped = []
        let port = config.socksPort
        let targets = config.targets
        let pick = choice
        route = Line(light: .yellow, word: pick == Tunnel.auto ? "probing" : "trying",
                     detail: pick == Tunnel.auto ? targets.map(\.host).joined(separator: ", ") : "")
        ssh = Line(light: .hollow, word: "down")
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
                self.lastFailureRetryable = false
                return
            }

            let target: Target
            if pick == Tunnel.auto {
                guard let found = await self.probeAll(targets, gen: gen) else { return }
                target = found
            } else {
                target = targets.first { $0.name == pick } ?? targets[0]
                self.route = Line(light: .yellow, word: "trying", detail: target.host)
            }
            guard gen == self.generation else { return }
            self.active = target
            self.launch(target, port: port, gen: gen)
        }
    }

    /// Probes every target's port 22 at once and returns the first in Settings order that answered.
    private func probeAll(_ targets: [Target], gen: Int) async -> Target? {
        let results = await withTaskGroup(of: (Int, ProbeResult).self) { group in
            for (i, t) in targets.enumerated() {
                group.addTask { (i, await Probe.tcp(host: t.host)) }
            }
            var out = [Int: ProbeResult]()
            for await (i, r) in group { out[i] = r }
            return out
        }
        guard gen == generation else { return nil }
        let summary = targets.indices.map { "\(targets[$0].host):22 \(results[$0]?.why ?? "no answer")" }
        note("probe " + summary.joined(separator: ", "))
        guard let i = targets.indices.first(where: { results[$0]?.isOpen == true }) else {
            route = Line(light: .red, word: "no route", detail: "no target answered on port 22")
            lastFailureRetryable = true
            scheduleRetry(gen: gen)
            return nil
        }
        skipped = targets.indices.filter { $0 < i }.map { "\(targets[$0].host) \(results[$0]?.why ?? "no answer")" }
        return targets[i]
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
        note((["/usr/bin/ssh"] + args).joined(separator: " "))
        ssh = Line(light: .yellow, word: "connecting", detail: t.userHost)

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
            let how = proc.terminationReason == .uncaughtSignal
                ? "was ended by signal \(proc.terminationStatus)"
                : "exited with status \(proc.terminationStatus)"
            Task { @MainActor in Tunnel.shared.exited(how: how, gen: gen) }
        }
        do {
            try p.run()
        } catch {
            ssh = Line(light: .red, word: "failed", detail: "could not start ssh")
            note("could not start /usr/bin/ssh: \(error.localizedDescription)")
            lastFailureRetryable = false
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
            guard gen == generation, process != nil, let t = active else { return }
            if await Task.detached(operation: { System.canConnect(port) }).value {
                guard gen == generation else { return }
                connectedAt = Date()
                attempt = 0
                ssh = Line(light: .green, word: "up", detail: t.userHost)
                socks = Line(light: .green, word: "127.0.0.1:\(port)")
                note("socks up on 127.0.0.1:\(port)")
                updateRouteLine()
                startStickLoop(gen: gen)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard gen == generation, process != nil else { return }
        note("socks port did not open within 10 s, stopping ssh")
        forcedReason = "timed out"
        process?.terminate()
    }

    /// Every 30 s while up: ask the stick, and re-read what Tailscale knows about the path.
    private func startStickLoop(gen: Int) {
        stickLoop?.cancel()
        stickLoop = Task {
            var first = true
            while !Task.isCancelled, gen == self.generation, self.process != nil {
                await self.checkStick(gen: gen)
                if first {
                    // Tailscale only knows direct or relayed once traffic has flowed.
                    try? await Task.sleep(for: .seconds(2))
                    first = false
                }
                await self.refreshPeer(gen: gen)
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

    private func refreshPeer(gen: Int) async {
        guard let host = active?.host else { return }
        let state = await Task.detached { Tailscale.state(for: host) }.value
        guard gen == generation, process != nil else { return }
        if state != peer {
            switch state {
            case .peer(let p): note("tailscale: peer \(p.online ? "online" : "offline"), \(Self.words(p.path))")
            case .notRunning(let s): note("tailscale: not running (\(s))")
            case .notAPeer, .unknown: break
            }
        }
        peer = state
        updateRouteLine()
    }

    /// Builds the route line from the target in use, what was skipped, and the Tailscale state.
    private func updateRouteLine() {
        guard let t = active, connectedAt != nil else { return }
        var word = t.name
        var light = Light.green
        var detail = [t.host]
        if !skipped.isEmpty { detail.append(contentsOf: skipped) }
        switch peer {
        case nil:
            break
        case .peer(let p):
            switch p.path {
            case .direct: word += ", direct"
            case .relayed(let via): word += ", relayed via \(via)"; light = .yellow
            case .idle: break
            }
            detail.append(p.online ? "peer online" : "peer offline")
        case .notRunning:
            if t.signIn == .tailnet { detail.append("Tailscale not running") }
        case .unknown:
            if t.signIn == .tailnet { detail.append("tailnet state unknown") }
        case .notAPeer:
            break
        }
        route = Line(light: light, word: word, detail: detail.joined(separator: ", "))
    }

    private static func words(_ path: PeerState.Path) -> String {
        switch path {
        case .direct: "direct"
        case .relayed(let via): "relayed via \(via)"
        case .idle: "idle"
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

    private func exited(how: String, gen: Int) {
        guard gen == generation else { return }
        stickLoop?.cancel()
        let wasUp = connectedAt != nil
        process = nil
        connectedAt = nil
        peer = nil
        Orphan.clear()
        socks = Line(light: .hollow, word: "off")
        stick = Line(light: .hollow, word: "not checked")
        if stopping {
            ssh = Line(light: .hollow, word: "down")
            route = Line(light: .hollow, word: "not tried")
            note("ssh stopped")
            return
        }
        let why = forcedReason ?? Self.reason(stderrText)
        note("ssh \(how): \(why)" + (wasUp ? " (was up)" : ""))
        ssh = Line(light: .red, word: "failed", detail: why)
        let host = active?.host ?? ""
        if ["name not found", "timed out", "refused"].contains(why) {
            route = Line(light: .red, word: "no route", detail: "\(host): \(why)")
        } else if why == "link lost" {
            route = Line(light: .red, word: "lost", detail: host)
        } else {
            route = Line(light: .hollow, word: "not tried")
        }
        lastFailureRetryable = Self.retryable.contains(why)
        if lastFailureRetryable { scheduleRetry(gen: gen) }
    }

    /// Failures that a new attempt, or a better network, can fix. The rest need a person.
    static let retryable: Set<String> = ["name not found", "timed out", "refused", "link lost", "exited"]

    /// Maps ssh's error text to one of the state words in SPEC.md.
    static func reason(_ stderr: String) -> String {
        let e = stderr.lowercased()
        if e.contains("remote host identification has changed") { return "host key changed" }
        if e.contains("host key verification failed") { return "host key unknown" }
        if e.contains("permission denied") { return "sign-in refused" }
        if e.contains("address already in use") || e.contains("cannot listen to port")
            || e.contains("could not request local forwarding") { return "port in use" }
        if e.contains("could not resolve hostname") { return "name not found" }
        if e.contains("not responding") || e.contains("broken pipe") || e.contains("connection reset")
            || e.contains("closed by remote host") || e.contains("connection closed") { return "link lost" }
        if e.contains("timed out") { return "timed out" }
        if e.contains("connection refused") { return "refused" }
        return "exited"
    }

    // MARK: retry and network changes

    /// Waits 2, 4, 8, 16, then 30 s between attempts, and starts again with a fresh route choice.
    private func scheduleRetry(gen: Int) {
        attempt += 1
        let delay = min(Double(1 << min(attempt, 5)), 30)
        retryAt = Date().addingTimeInterval(delay)
        note("next attempt in \(Int(delay)) s")
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, gen == self.generation, self.wantsConnection else { return }
            self.start()
        }
    }

    private func networkChanged(_ summary: String) {
        guard sawFirstPath else { sawFirstPath = true; return }
        netDebounce?.cancel()
        netDebounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.note("network changed (\(summary))")
            if self.process == nil {
                if self.wantsConnection && self.lastFailureRetryable {
                    self.note("trying again now")
                    self.start()
                }
            } else {
                let gen = self.generation
                await self.checkStick(gen: gen)
                await self.refreshPeer(gen: gen)
            }
        }
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "offline" }
        var kinds: [String] = []
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("ethernet") }
        if path.usesInterfaceType(.wifi) { kinds.append("wifi") }
        if path.usesInterfaceType(.cellular) { kinds.append("cellular") }
        if path.usesInterfaceType(.other) { kinds.append("other") }
        return kinds.isEmpty ? "online" : kinds.joined(separator: ", ")
    }

    // MARK: stop

    /// Stops ssh and waits up to 2 s before killing it. Used on reconnect and at quit.
    func stop() {
        generation += 1
        stopping = true
        wantsConnection = false
        retryTask?.cancel()
        retryAt = nil
        stickLoop?.cancel()
        guard let p = process else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        connectedAt = nil
        peer = nil
        Orphan.clear()
        ssh = Line(light: .hollow, word: "down")
        socks = Line(light: .hollow, word: "off")
        stick = Line(light: .hollow, word: "not checked")
        route = Line(light: .hollow, word: "not tried")
        note("ssh stopped")
    }

    /// Reconnect button and route switch: start over now, with the backoff reset.
    func reconnect() {
        stop()
        attempt = 0
        start()
    }

    func note(_ s: String) {
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
