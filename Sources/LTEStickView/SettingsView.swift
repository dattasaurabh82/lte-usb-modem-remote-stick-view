import SwiftUI

/// The Settings window (Cmd-comma, or the gear in the main window).
/// Edits a draft; Apply saves it and reconnects. Passwords go straight to the Keychain.
struct SettingsView: View {
    let tunnel: Tunnel
    @State private var draft = Config()
    @State private var loaded = false
    @State private var portText = ""
    @State private var stickText = ""
    @State private var problem: String?
    @State private var detectReport: String?
    @State private var detecting = false
    @State private var browsers: [Browser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 28) {
                targetsColumn.frame(width: 380)
                rightColumn.frame(width: 300)
            }
            Divider()
            HStack {
                if let problem {
                    Text(problem).foregroundStyle(Light.red.color).font(.callout)
                } else if draft != tunnel.config || portText != "\(draft.socksPort)" || stickText != draft.stickURL.absoluteString {
                    Text("Changes are applied with a reconnect.").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Revert") { load() }
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { if !loaded { load(); loaded = true }; browsers = Browsers.detect() }
    }

    // MARK: targets

    private var targetsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Targets, tried in this order").foregroundStyle(.secondary)
            ForEach(draft.targets.indices, id: \.self) { i in
                TargetEditor(target: $draft.targets[i],
                             canMoveUp: i > 0, canMoveDown: i < draft.targets.count - 1, canDelete: draft.targets.count > 1,
                             moveUp: { draft.targets.swapAt(i, i - 1) },
                             moveDown: { draft.targets.swapAt(i, i + 1) },
                             delete: { draft.targets.remove(at: i) })
                Divider()
            }
            Button("Add target") {
                draft.targets.append(Target(name: "New target", userHost: "root@", signIn: .key))
            }
            Text("A target in password mode keeps its password in the Keychain, saved with the Save button next to it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: stick, port, browsers

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stick address").foregroundStyle(.secondary)
            HStack {
                TextField("http://192.168.8.1/", text: $stickText)
                    .font(.system(.body, design: .monospaced))
                Button(detecting ? "Asking\u{2026}" : "Detect from box") { detect() }
                    .disabled(detecting)
            }
            if let detectReport {
                Text(detectReport).font(.caption).foregroundStyle(.secondary)
            }

            Text("SOCKS port").foregroundStyle(.secondary).padding(.top, 8)
            TextField("1080", text: $portText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)

            Text("Browsers found on this Mac").foregroundStyle(.secondary).padding(.top, 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { Dot(light: .green); Text("Built-in viewer"); Text("WebKit, in the app").foregroundStyle(.secondary) }
                ForEach(browsers) { b in
                    HStack(spacing: 8) {
                        Dot(light: !b.usable ? .hollow : (b.tested ? .green : .yellow))
                        Text(b.name).foregroundStyle(b.usable ? .primary : .secondary)
                        Text(b.usable && !b.tested ? "untested" : b.how).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: actions

    private func load() {
        draft = tunnel.config
        portText = "\(draft.socksPort)"
        stickText = draft.stickURL.absoluteString
        problem = nil
    }

    private func detect() {
        detecting = true
        detectReport = nil
        Task {
            let (url, report) = await tunnel.detectStick()
            detecting = false
            detectReport = report
            if let url { stickText = url.absoluteString }
        }
    }

    /// Checks the draft, then hands it to the tunnel.
    private func apply() {
        problem = nil
        guard let url = URL(string: stickText.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host() != nil else {
            problem = "The stick address must be a web address such as http://192.168.8.1/"
            return
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            problem = "The SOCKS port must be a number from 1024 to 65535."
            return
        }
        for t in draft.targets {
            let name = t.name.trimmingCharacters(in: .whitespaces)
            let parts = t.userHost.split(separator: "@")
            if name.isEmpty || parts.count != 2 || parts.contains(where: { $0.isEmpty }) {
                problem = "Every target needs a name and a user@host."
                return
            }
        }
        if Set(draft.targets.map(\.name)).count != draft.targets.count {
            problem = "Two targets have the same name."
            return
        }
        if port != tunnel.config.socksPort && !System.portIsFree(port) {
            let who = System.listenerName(port).map { " by \($0)" } ?? ""
            let next = (Int(port) + 1...65535).first { System.portIsFree(UInt16($0)) }.map { " Port \($0) is free." } ?? ""
            problem = "Port \(port) is in use\(who).\(next)"
            return
        }
        draft.stickURL = url
        draft.socksPort = port
        tunnel.apply(draft)
        load()
    }
}

/// One editable target: name, user@host, sign-in mode, order, and for password mode the Keychain password.
struct TargetEditor: View {
    @Binding var target: Target
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canDelete: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    @State private var password = ""
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $target.name).frame(width: 120)
                TextField("user@host", text: $target.userHost)
                    .font(.system(.body, design: .monospaced))
                Button { moveUp() } label: { Image(systemName: "chevron.up") }.disabled(!canMoveUp).help("Try earlier")
                Button { moveDown() } label: { Image(systemName: "chevron.down") }.disabled(!canMoveDown).help("Try later")
                Button { delete() } label: { Image(systemName: "trash") }.disabled(!canDelete).help("Remove")
            }
            .buttonStyle(.borderless)
            Picker("Sign-in", selection: $target.signIn) {
                Text("Tailnet").tag(SignIn.tailnet)
                Text("Key").tag(SignIn.key)
                Text("Password").tag(SignIn.password)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if target.signIn == .password {
                HStack {
                    SecureField(Keychain.password(for: target.userHost) == nil ? "Not saved" : "Saved in the Keychain", text: $password)
                    Button("Save") {
                        saved = Keychain.set(password, for: target.userHost)
                            ? "Saved for \(target.userHost)" : "The Keychain refused it"
                        password = ""
                    }
                    .disabled(password.isEmpty)
                    Button("Forget") {
                        Keychain.delete(target.userHost)
                        saved = "Removed for \(target.userHost)"
                    }
                }
                if let saved { Text(saved).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
