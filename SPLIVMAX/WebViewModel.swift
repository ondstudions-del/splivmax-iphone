import SwiftUI
import WebKit
import Network

@MainActor
final class WebViewModel: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var isPlayer = false
    @Published private(set) var isOffline = false

    let webView: WKWebView
    private let refreshControl = UIRefreshControl()
    private var observations: [NSKeyValueObservation] = []
    private let monitor = NWPathMonitor()
    private var failedURL: URL?

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
            WKUserScript(source: AppConfig.injectedScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

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

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                if self?.isOffline == true { self?.retry() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "splivmax.network"))

        webView.load(URLRequest(url: AppConfig.homeURL))
    }

    deinit {
        monitor.cancel()
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
        webView.allowsBackForwardNavigationGestures = !player
        webView.scrollView.refreshControl = player ? nil : refreshControl
        OrientationController.setPlayerMode(player)
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
        if !hasLoadedOnce { hasLoadedOnce = true }
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
