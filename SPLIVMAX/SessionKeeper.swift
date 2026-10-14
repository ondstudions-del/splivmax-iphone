import WebKit

/// Mantiene la sesión iniciada aunque se cierre la app.
/// WKWebView borra las cookies "de sesión" (sin fecha de caducidad) cuando iOS termina la app, así que
/// las cookies seguras del sitio se guardan con caducidad y se renuevan cada vez que se usa la app.
@MainActor
final class SessionKeeper: NSObject {
    private let store: WKHTTPCookieStore

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
        store.add(self)
        renew()
    }

    func renew() {
        store.getAllCookies { [weak self] cookies in
            self?.persist(cookies)
        }
    }

    private func persist(_ cookies: [HTTPCookie]) {
        let lifetime = AppConfig.sessionDays * 86_400
        let renewBefore = Date(timeIntervalSinceNow: lifetime - 86_400)
        for cookie in cookies where cookie.isHTTPOnly && AppConfig.isInternalHost(cookie.domain) {
            if let expires = cookie.expiresDate, expires > renewBefore { continue }
            if let expires = cookie.expiresDate, expires < Date() { continue }
            guard var properties = cookie.properties else { continue }
            properties[.expires] = Date(timeIntervalSinceNow: lifetime)
            properties.removeValue(forKey: .discard)
            properties.removeValue(forKey: .maximumAge)
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            if let renewed = HTTPCookie(properties: properties) {
                store.setCookie(renewed)
            }
        }
    }
}

extension SessionKeeper: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.renew() }
    }
}
