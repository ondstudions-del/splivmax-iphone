import SwiftUI
import WebKit
import Network

@MainActor
final class WebViewModel: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var isPlayer = false
    @Published private(set) var isFullscreen = false
    @Published private(set) var isOffline = false

    /// Página del reproductor o vídeo a pantalla completa: horizontal y sin barras del sistema.
    var isImmersive: Bool { isPlayer || isFullscreen }

    let webView: WKWebView
    private let refreshControl = UIRefreshControl()
    private var observations: [NSKeyValueObservation] = []
    private let monitor = NWPathMonitor()
    private var failedURL: URL?
    private var sessionKeeper: SessionKeeper?
    private var openURLObserver: NSObjectProtocol?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.applicationNameForUserAgent = AppConfig.userAgentSuffix
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        if #available(iOS 15.4, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        config.userContentController.addUserScript(
            WKUserScript(source: AppConfig.documentStartScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController.addUserScript(
            WKUserScript(source: AppConfig.injectedScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let bridge = ScriptBridge()
        config.userContentController.add(bridge, name: AppConfig.bridgeName)

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.owner = self
        let keeper = SessionKeeper(store: config.websiteDataStore.httpCookieStore)
        sessionKeeper = keeper

        webView.isOpaque = false
        webView.backgroundColor = AppConfig.uiBackground
        webView.scrollView.backgroundColor = AppConfig.uiBackground
        // El sitio ya respeta la muesca y la barra de inicio con env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        refreshControl.tintColor = .white
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let value = wv.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let value = wv.isLoading
                Task { @MainActor in self?.isLoading = value }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let url = wv.url
                Task { @MainActor in self?.urlChanged(url) }
            },
        ]
        if #available(iOS 16.0, *) {
            // Pantalla completa nativa de WebKit (por ejemplo, desde el iframe de un reproductor externo).
            observations.append(webView.observe(\.fullscreenState, options: [.new]) { [weak self] wv, _ in
                let on = wv.fullscreenState == .enteringFullscreen || wv.fullscreenState == .inFullscreen
                Task { @MainActor in self?.setFullscreen(on) }
            })
        }

        openURLObserver = NotificationCenter.default.addObserver(forName: .splivmaxOpenURL, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openPendingURL() }
        }

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                if self?.isOffline == true { self?.retry() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "splivmax.network"))

        // La primera página espera a que se repongan las cookies guardadas, para que la sesión ya esté iniciada.
        keeper.start { [weak self] in
            guard let self, self.webView.url == nil else { return }
            self.webView.load(URLRequest(url: NotificationManager.shared.takePendingURL() ?? AppConfig.homeURL))
        }
    }

    deinit {
        monitor.cancel()
    }

    private func openPendingURL() {
        guard let url = NotificationManager.shared.takePendingURL() else { return }
        isOffline = false
        webView.load(URLRequest(url: url))
    }

    func retry() {
        isOffline = false
        if let url = failedURL ?? webView.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: AppConfig.homeURL))
        }
        failedURL = nil
    }

    @objc private func pullToRefresh() {
        if webView.url == nil {
            retry()
        } else {
            webView.reload()
        }
    }

    private func urlChanged(_ url: URL?) {
        let player = AppConfig.isPlayer(url)
        guard player != isPlayer else { return }
        isPlayer = player
        isFullscreen = false
        updateImmersiveMode()
    }

    fileprivate func setFullscreen(_ on: Bool) {
        guard on != isFullscreen else { return }
        isFullscreen = on
        updateImmersiveMode()
    }

    private func updateImmersiveMode() {
        let on = isImmersive
        webView.allowsBackForwardNavigationGestures = !on
        webView.scrollView.refreshControl = on ? nil : refreshControl
        // En el reproductor la página no debe desplazarse ni rebotar al tocar los controles.
        webView.scrollView.isScrollEnabled = !on
        webView.scrollView.bounces = !on
        OrientationController.setLandscape(on)
    }

    /// Mensajes de la web (window.SPLIVMAXApp y avisos de pantalla completa).
    fileprivate func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "fullscreen" {
            setFullscreen(body["on"] as? Bool ?? false)
            return
        }
        // Las notificaciones sólo puede pedirlas el propio sitio, no los iframes de terceros.
        guard message.frameInfo.isMainFrame, AppConfig.isInternalHost(message.frameInfo.securityOrigin.host) else { return }
        let notifications = NotificationManager.shared
        let title = String((body["title"] as? String ?? "").prefix(120))
        let text = String((body["body"] as? String ?? "").prefix(400))
        let link = body["link"] as? String
        switch type {
        case "notify":
            guard !title.isEmpty || !text.isEmpty else { return }
            notifications.deliver(id: "web-\(UUID().uuidString)", title: title, body: text, link: link)
        case "schedule":
            guard let id = body["id"] as? String, !id.isEmpty, let at = body["at"] as? Double, at.isFinite else { return }
            notifications.deliver(id: "web-\(id)", title: title, body: text, link: link, at: Date(timeIntervalSince1970: at))
        case "cancel":
            if let id = body["id"] as? String { notifications.cancel(id: "web-\(id)") }
        case "permission":
            Task { await notifications.requestAuthorizationIfNeeded() }
        case "check":
            Task { await notifications.check() }
        default:
            break
        }
    }

    private func rememberUserAgent() {
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            guard let agent = value as? String, !agent.isEmpty else { return }
            Task { @MainActor in
                let manager = NotificationManager.shared
                let first = manager.userAgent == nil
                manager.userAgent = agent
                if first { await manager.check() }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // descarga interrumpida por política
        let offlineCodes = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
        ]
        if nsError.domain == NSURLErrorDomain && offlineCodes.contains(nsError.code) {
            failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
            isOffline = true
        }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private static var topViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Navegación

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }

        // mailto:, tel:, whatsapp:, itms-apps:… se abren con su app.
        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            openExternally(url)
            return .cancel
        }

        // Enlaces que el usuario toca hacia otros sitios (compartir en redes, etc.) se abren fuera.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, navigationAction.navigationType == .linkActivated, !AppConfig.isInternal(url) {
            openExternally(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isOffline = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        isOffline = false
        if !hasLoadedOnce {
            hasLoadedOnce = true
            rememberUserAgent()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Puente JavaScript → app

/// Intermediario con referencia débil: WKUserContentController retiene a su manejador y,
/// si fuera el propio modelo, nunca se liberaría.
@MainActor
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handle(message)
    }
}

// MARK: - Ventanas nuevas y diálogos

extension WebViewModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if AppConfig.isInternal(url) {
            webView.load(navigationAction.request)
        } else if navigationAction.navigationType == .linkActivated {
            openExternally(url)
        }
        // Las ventanas emergentes que no abre el usuario (publicidad de los reproductores externos) se bloquean.
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in continuation.resume() })
            guard let top = Self.topViewController else { continuation.resume(); return }
            top.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in continuation.resume(returning: true) })
            guard let top = Self.topViewController else { continuation.resume(returning: false); return }
            top.present(alert, animated: true)
        }
    }
}
