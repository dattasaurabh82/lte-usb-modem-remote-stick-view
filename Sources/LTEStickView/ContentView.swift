import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var tunnel: Tunnel
    @State private var logOpen = true

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
        .task { tunnel.start() }
        .onChange(of: tunnel.choice) { tunnel.reconnect() }
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
