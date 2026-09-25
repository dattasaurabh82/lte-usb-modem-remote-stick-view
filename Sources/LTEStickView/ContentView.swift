import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var tunnel: Tunnel
    @State private var logOpen = true
    @State private var viewers = 0
    @State private var chooserOpen = false
    /// A browser picked before the stick answered; it opens when the stick line turns green.
    @State private var pending: Browser?
    /// "builtin" or a bundle identifier. Only labels the chooser row, never preselects it.
    @AppStorage("lastViewer") private var lastViewer = ""
    @Environment(\.openWindow) private var openWindow
    /// --open-viewer opens the built-in viewer right at launch, for checks from a terminal.
    private let autoOpen = CommandLine.arguments.contains("--open-viewer")
    /// --show-chooser opens the chooser at launch, for screenshots.
    private let showChooser = CommandLine.arguments.contains("--show-chooser")
    /// --open-in <name> opens that browser right at launch (waiting for the stick), for checks from a terminal.
    private let openIn: String? = CommandLine.arguments.firstIndex(of: "--open-in")
        .flatMap { CommandLine.arguments.dropFirst($0 + 1).first?.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Route").foregroundStyle(.secondary)
                Picker("Route", selection: $tunnel.choice) {
                    Text("Auto").tag(Tunnel.auto)
                    ForEach(tunnel.config.targets, id: \.name) { t in
                        Text(t.name).tag(t.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 10)

            StatusRow(name: "route", line: tunnel.route)
            Divider()
            StatusRow(name: "tailscale", line: tunnel.tailscale,
                      action: tunnel.tailscaleFix.map { fix in (fix.label, { tunnel.applyTailscaleFix() }) })
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                StatusRow(name: "ssh session", line: sshLine(at: ctx.date))
            }
            Divider()
            StatusRow(name: "socks proxy", line: tunnel.socks, mono: tunnel.socks.light == .green)
            Divider()
            StatusRow(name: "lte stick", line: tunnel.stick)

            HStack {
                Button("Open stick page\u{2026}") { chooserOpen = true }
                .buttonStyle(.borderedProminent)
                .help("Asks where to open the stick's page, every time")
                .popover(isPresented: $chooserOpen, arrowEdge: .bottom) {
                    // The chooser reads the browsers, the tunnel and the last choice itself: a popover's
                    // content does not follow the parent's state once it is shown.
                    Chooser(tunnel: tunnel, pick: { choice in chooserOpen = false; choose(choice) })
                }
                if !tunnel.isActive {
                    Button("Reconnect") { tunnel.reconnect() }
                }
                Spacer()
                Text("closing this window ends the tunnel")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(.top, 14)

            Divider().padding(.top, 14)

            DisclosureGroup("Command and log", isExpanded: $logOpen) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(tunnel.log.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("end")
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: tunnel.log.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .padding(.top, 6)
            }
            .padding(.top, 10)
        }
        .padding(18)
        .frame(width: 640)
        .task {
            tunnel.start()
            if autoOpen { openViewer() }
            if showChooser {
                try? await Task.sleep(for: .seconds(4))
                chooserOpen = true
            }
            if let openIn {
                if let b = Browsers.detect().first(where: { $0.name.lowercased().contains(openIn) }) {
                    choose(.browser(b))
                } else {
                    tunnel.note("--open-in: no browser matches \"\(openIn)\"")
                }
            }
        }
        .onChange(of: tunnel.stick.light) { _, now in
            guard now == .green, let b = pending else { return }
            pending = nil
            Browsers.launch(b, url: tunnel.config.stickURL, socksPort: tunnel.config.socksPort)
        }
        // Closing this window quits the app, even while viewer windows are open.
        .onDisappear { NSApp.terminate(nil) }

        .onChange(of: tunnel.choice) { tunnel.reconnect() }
    }

    private func choose(_ choice: ViewerChoice) {
        switch choice {
        case .builtin:
            lastViewer = "builtin"
            openViewer()
        case .browser(let b):
            guard b.usable else { return }
            lastViewer = b.bundleID
            if tunnel.stick.light == .green {
                Browsers.launch(b, url: tunnel.config.stickURL, socksPort: tunnel.config.socksPort)
            } else {
                pending = b
                tunnel.note("\(b.name) opens as soon as the stick answers through the tunnel")
            }
        }
    }

    private func openViewer() {
        viewers += 1
        tunnel.note("opening the stick page in the built-in viewer")
        openWindow(id: "viewer", value: viewers)
    }

    private func sshLine(at now: Date) -> Line {
        if let at = tunnel.retryAt, !tunnel.isActive {
            let left = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
            let when = left > 0 ? "retry in \(left) s" : "retrying now"
            return Line(light: .yellow, word: "waiting",
                        detail: "\(when), attempt \(tunnel.attempt + 1), last: \(tunnel.lastReason)")
        }
        guard let since = tunnel.connectedAt, tunnel.ssh.light == .green else { return tunnel.ssh }
        let s = Int(now.timeIntervalSince(since))
        let up = String(format: "up %02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        return Line(light: .green, word: up, detail: tunnel.ssh.detail)
    }
}

struct StatusRow: View {
    let name: String
    let line: Line
    var mono = false
    /// An optional one-click fix shown at the end of the row.
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Dot(light: line.light)
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(line.word)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(line.light.wordColor)
            Text(line.detail)
                .foregroundStyle(.tertiary)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let action {
                Button(action.label, action: action.run)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(line.light == .red ? line.light.color : nil)
            }
        }
        .padding(.vertical, 7)
    }
}

struct Dot: View {
    let light: Light

    var body: some View {
        Group {
            if light == .hollow {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            } else {
                Circle().fill(light.color)
            }
        }
        .frame(width: 9, height: 9)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
    }
}

extension Light {
    var color: Color {
        switch self {
        case .green: Color(red: 0.16, green: 0.65, blue: 0.27)
        case .yellow: Color(red: 0.88, green: 0.66, blue: 0.0)
        case .red: Color(red: 0.85, green: 0.20, blue: 0.17)
        case .hollow: .secondary
        }
    }

    /// State words are coloured by meaning; green words stay in the primary colour.
    var wordColor: Color {
        switch self {
        case .green: .primary
        case .yellow: color
        case .red: color
        case .hollow: .secondary
        }
    }
}

enum ViewerChoice {
    case builtin
    case browser(Browser)
}

/// The list that opens from Open stick page: the built-in viewer, then the browsers found on this Mac.
struct Chooser: View {
    let tunnel: Tunnel
    let pick: (ViewerChoice) -> Void
    @State private var browsers: [Browser] = []
    @AppStorage("lastViewer") private var lastViewer = ""

    private var tunnelUp: Bool { tunnel.stick.light == .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tunnelUp {
                Text("The tunnel is not up yet. A browser opens as soon as the stick answers; the built-in viewer waits in its window.")
                    .font(.callout)
                    .foregroundStyle(Light.yellow.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider()
            }
            ChooserRow(light: .green, name: "Built-in viewer",
                       detail: lastViewer == "builtin" ? "last used" : "WebKit, in the app",
                       enabled: true, why: "") { pick(.builtin) }
            ForEach(browsers) { b in
                Divider()
                ChooserRow(light: light(b), name: b.name, detail: detail(b), enabled: b.usable,
                           why: b.family == .ignoresOptions
                               ? "\(b.name) ignores the launch options that carry the proxy rule"
                               : "\(b.name) only follows the system-wide proxy, which this app does not change") { pick(.browser(b)) }
            }
        }
        .frame(width: 320)
        .onAppear {
            // Found fresh every time the chooser opens, so a browser installed meanwhile shows up.
            browsers = Browsers.detect()
            tunnel.note("chooser: " + browsers.map { "\($0.name) (\($0.how))" }.joined(separator: ", "))
        }
    }

    private func light(_ b: Browser) -> Light {
        if !b.usable { return .hollow }
        return b.tested ? .green : .yellow
    }

    private func detail(_ b: Browser) -> String {
        if !b.usable { return b.how }
        if !b.tested { return lastViewer == b.bundleID ? "untested, last used" : "untested" }
        return lastViewer == b.bundleID ? "last used" : b.how
    }
}

struct ChooserRow: View {
    let light: Light
    let name: String
    let detail: String
    let enabled: Bool
    /// Shown as a tooltip on rows that cannot be used.
    let why: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Dot(light: light)
            Text(name).foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 12)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hover && enabled ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if enabled { action() } }
        .help(enabled ? "Open the stick page here" : why)
    }
}
