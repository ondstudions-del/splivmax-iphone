import WebKit
import Security

/// Mantiene la sesión iniciada aunque se cierre la app.
/// WKWebView borra las cookies "de sesión" (sin fecha de caducidad) cuando iOS termina la app, así que
/// las cookies seguras del sitio se guardan con caducidad y se renuevan cada vez que se usa la app.
/// Además se guarda una copia en el llavero del iPhone: si iOS borra los datos de la vista web
/// (poco espacio, actualización de la app…), se reponen antes de cargar la primera página.
@MainActor
final class SessionKeeper: NSObject {
    private let store: WKHTTPCookieStore
    private var started = false

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
    }

    /// Repone la copia del llavero si faltan cookies y después empieza a vigilar los cambios.
    func start(then ready: @escaping @MainActor () -> Void) {
        store.getAllCookies { [weak self] current in
            Task { @MainActor in
                guard let self else { ready(); return }
                await self.restore(missingFrom: current)
                self.started = true
                self.store.add(self)
                self.renew()
                ready()
            }
        }
    }

    func renew() {
        guard started else { return }
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.persist(cookies)
                CookieVault.save(cookies.filter(Self.isSite))
            }
        }
    }

    private nonisolated static func isSite(_ cookie: HTTPCookie) -> Bool {
        AppConfig.isInternalHost(cookie.domain)
    }

    private nonisolated static func isSiteSession(_ cookie: HTTPCookie) -> Bool {
        cookie.isHTTPOnly && isSite(cookie)
    }

    private func restore(missingFrom current: [HTTPCookie]) async {
        let store = self.store
        let present = Set(current.filter(Self.isSite).map { "\($0.domain)|\($0.path)|\($0.name)" })
        for cookie in CookieVault.load() where !present.contains("\(cookie.domain)|\(cookie.path)|\(cookie.name)") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func persist(_ cookies: [HTTPCookie]) {
        let lifetime = AppConfig.sessionDays * 86_400
        let renewBefore = Date(timeIntervalSinceNow: lifetime - 86_400)
        for cookie in cookies where Self.isSiteSession(cookie) {
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

/// Copia de las cookies de sesión del sitio en el llavero (sólo en este iPhone, no se sincroniza con iCloud).
private enum CookieVault {
    private static let service = "com.ondstudios.splivmax.session"
    private static let account = "cookies"

    private struct Stored: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date
        let secure: Bool
        let sameSite: String?
    }

    static func save(_ cookies: [HTTPCookie]) {
        let now = Date()
        let items = cookies.compactMap { c -> Stored? in
            guard let expires = c.expiresDate, expires > now else { return nil }
            return Stored(name: c.name, value: c.value, domain: c.domain, path: c.path, expires: expires,
                          secure: c.isSecure, sameSite: c.sameSitePolicy?.rawValue)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        if data == read() { return }
        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> [HTTPCookie] {
        guard let data = read(), let items = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        let now = Date()
        return items.compactMap { s in
            guard s.expires > now, AppConfig.isInternalHost(s.domain) else { return nil }
            var p: [HTTPCookiePropertyKey: Any] = [
                .name: s.name, .value: s.value, .domain: s.domain, .path: s.path, .expires: s.expires,
                HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            ]
            if s.secure { p[.secure] = "TRUE" }
            if let sameSite = s.sameSite { p[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: p)
        }
    }

    private static func read() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
