import AppKit
import Network
import SwiftUI
import WebKit

/// One viewer window: a WebKit view whose traffic goes only through the tunnel's SOCKS port.
/// Each window has its own non-persistent data store, so nothing outlives the window.
@MainActor
@Observable
final class ViewerModel: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let start: URL
    private(set) var title = ""
    private(set) var address = ""
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var loadedOnce = false
    /// Set when the tunnel dropped after the page loaded: the page's own polling is broken, reload when back.
    private(set) var stale = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    init(start: URL, socksPort: UInt16) {
        self.start = start
        let store = WKWebsiteDataStore.nonPersistent()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: socksPort)!)
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        address = start.absoluteString
    }

    func markStale() {
        if loadedOnce { stale = true }
    }

    func load() {
        failure = nil
        stale = false
        webView.load(URLRequest(url: start, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
    }

    func reload() {
        if loadedOnce { failure = nil; webView.reload() } else { load() }
    }

    private func refresh() {
        title = webView.title ?? ""
        address = webView.url?.absoluteString ?? start.absoluteString
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        refresh()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        loadedOnce = true
        failure = nil
        refresh()
        Tunnel.shared.note("viewer: loaded \(address)" + (title.isEmpty ? "" : ", title \"\(title)\""))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        // A navigation replaced by a newer one is not a failure.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        loading = false
        failure = e.localizedDescription
        refresh()
        Tunnel.shared.note("viewer: could not load \(address): \(e.localizedDescription) (\(e.domain) \(e.code))")
    }
}

/// Hosts the WKWebView in SwiftUI.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ViewerWindow: View {
    let tunnel: Tunnel
    @State private var model: ViewerModel

    init(tunnel: Tunnel) {
        self.tunnel = tunnel
        _model = State(initialValue: ViewerModel(start: tunnel.config.stickURL, socksPort: tunnel.config.socksPort))
    }

    private var tunnelUp: Bool { tunnel.socks.light == .green }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                    .focusable(false)
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                    .focusable(false)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .focusable(false)
                Text(model.address)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Dot(light: tunnelUp ? .green : .yellow)
                Text(tunnelUp ? "through the tunnel, \(tunnel.route.word)" : "waiting for the tunnel")
                    .font(.callout)
                    .foregroundStyle(tunnelUp ? .secondary : Light.yellow.color)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                WebViewHost(webView: model.webView)
                if let failure = model.failure {
                    notice(title: "The stick page did not load", body: failure + "\n\nIt loads again by itself when the tunnel is back, or press reload.")
                } else if !tunnelUp && !model.loadedOnce {
                    notice(title: "Waiting for the tunnel", body: "The page opens as soon as the lte stick line in the main window is green.")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .navigationTitle(model.title.isEmpty ? "Stick page" : model.title)
        .onAppear { if tunnelUp { model.load() } }
        .onChange(of: tunnelUp) { _, up in
            if !up { model.markStale() }
        }
        .onChange(of: tunnel.stick.light) { _, now in
            // Load, or reload after a failure or a dropped tunnel, as soon as the stick answers again.
            guard now == .green else { return }
            if !model.loadedOnce || model.failure != nil || model.stale {
                if model.stale { tunnel.note("viewer: the tunnel is back, reloading the page") }
                model.load()
            }
        }
    }

    private func notice(title: String, body: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3)
            Text(body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
