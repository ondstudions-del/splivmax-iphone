import Foundation

struct APIError: Error, LocalizedError, Identifiable, Equatable {
    let status: Int
    let code: String
    let message: String
    var fields: [String: String] = [:]

    var id: String { "\(status)-\(code)-\(message)" }
    var errorDescription: String? { message }

    /// Mensaje principal más los errores de cada campo (formularios).
    var fullMessage: String {
        let extra = fields.values.filter { $0 != message }.sorted()
        return ([message] + extra).joined(separator: "\n")
    }

    var isOffline: Bool { code == "offline" }

    static let offline = APIError(status: 0, code: "offline", message: "Sin conexión a internet. Revisa tu red e inténtalo de nuevo.")
    static let timeout = APIError(status: 0, code: "timeout", message: "La conexión está muy lenta. Inténtalo de nuevo.")

    static func from(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timeout
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return APIError(status: 0, code: "tls", message: "No se pudo establecer una conexión segura con SPLIVMAX.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return APIError(status: 0, code: "unreachable", message: "No pudimos contactar con SPLIVMAX. Inténtalo en unos minutos.")
            default: break
            }
        }
        return APIError(status: 0, code: "network", message: "Ocurrió un problema de conexión. Inténtalo de nuevo.")
    }
}

extension Notification.Name {
    /// Errores que cambian el estado global: sesión caducada, perfil pendiente, mantenimiento.
    static let apiSessionEvent = Notification.Name("spx.api.sessionEvent")
}

/// Cliente de la API privada de SPLIVMAX. Sólo HTTPS; la clave de la app y el token viajan en cabeceras.
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    enum Method: String { case get = "GET", post = "POST" }

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let session: URLSession
    private let cache: URLCache
    private let lock = NSLock()
    private var storedToken: String?
    let deviceId: String

    var token: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedToken }
        set { lock.lock(); storedToken = newValue; lock.unlock() }
    }

    private init() {
        // HTTP cache del sistema + caché propia de JSON (ResponseCache).
        cache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 120 * 1024 * 1024)
        URLCache.shared = cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = cache
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Language": "es",
            "User-Agent": "SPLIVMAX-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0") (VLCKit; mkv)",
        ]
        session = URLSession(configuration: config)
        deviceId = KeychainStore.deviceId
    }

    /// Las respuestas dependen de la cuenta y del perfil: al cambiar de sesión se descarta la caché.
    func clearCache() {
        cache.removeAllCachedResponses()
        ResponseCache.shared.clear()
    }

    /// Ámbito de caché por perfil (evita mezclar catálogos).
    func setCacheScope(_ scope: String) {
        ResponseCache.shared.scope = scope
    }

    func send<T: Decodable>(_ method: Method = .get, _ path: String, query: [String: String] = [:],
                            body: [String: Any]? = nil, authorized: Bool = true,
                            timeout: TimeInterval? = nil,
                            as type: T.Type = T.self) async throws -> T {
        try await sendPage(method, path, query: query, body: body, authorized: authorized, timeout: timeout, as: type).data
    }

    func sendPage<T: Decodable>(_ method: Method = .get, _ path: String, query: [String: String] = [:],
                                body: [String: Any]? = nil, authorized: Bool = true,
                                timeout: TimeInterval? = nil,
                                as type: T.Type = T.self) async throws -> (data: T, meta: PageMeta?) {
        let resolved = Self.resolvePath(path)
        let cacheTTL = method == .get ? ResponseCache.ttl(for: resolved) : nil
        let cacheKey: String? = cacheTTL.map {
            ResponseCache.shared.key(path: resolved, query: query, authorized: authorized, tokenHint: token)
        }

        if let cacheKey, let ttl = cacheTTL, let entry = ResponseCache.shared.entry(for: cacheKey) {
            let online = await MainActor.run { NetworkMonitor.shared.isOnline }
            if entry.isFresh, let decoded = try? decodeSuccess(entry.data, as: T.self) {
                if entry.age > ttl * 0.5, online {
                    Task { [weak self] in
                        _ = try? await self?.fetchAndStore(
                            method, path, query: query, body: body,
                            authorized: authorized, timeout: timeout,
                            cacheKey: cacheKey, cacheTTL: ttl, as: T.self,
                        )
                    }
                }
                return decoded
            }
            if !online, entry.isUsableOffline, let decoded = try? decodeSuccess(entry.data, as: T.self) {
                return decoded
            }
        }

        do {
            return try await fetchAndStore(
                method, path, query: query, body: body,
                authorized: authorized, timeout: timeout,
                cacheKey: cacheKey, cacheTTL: cacheTTL, as: T.self,
            )
        } catch {
            if let cacheKey,
               let entry = ResponseCache.shared.entry(for: cacheKey),
               entry.isUsableOffline,
               let decoded = try? decodeSuccess(entry.data, as: T.self) {
                return decoded
            }
            throw error
        }
    }

    private func fetchAndStore<T: Decodable>(
        _ method: Method, _ path: String, query: [String: String],
        body: [String: Any]?, authorized: Bool, timeout: TimeInterval?,
        cacheKey: String?, cacheTTL: TimeInterval?,
        as type: T.Type,
    ) async throws -> (data: T, meta: PageMeta?) {
        var request = try makeRequest(method, path, query: query, body: body, authorized: authorized)
        if let timeout {
            request.timeoutInterval = timeout
        }
        let maxAttempts = path.hasPrefix("/playback/") ? 2 : 3
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let decoded = try handle(data: data, response: response, as: T.self)
                if let cacheKey, let cacheTTL, (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                    ResponseCache.shared.store(key: cacheKey, data: data, ttl: cacheTTL)
                }
                return decoded
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                attempt += 1
                if method == .get, attempt < maxAttempts, Self.isTransient(error) {
                    let delay = path.hasPrefix("/playback/") ? 350_000_000 : UInt64(attempt) * 600_000_000
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw APIError.from(error)
            }
        }
    }

    private func makeRequest(_ method: Method, _ path: String, query: [String: String], body: [String: Any]?, authorized: Bool) throws -> URLRequest {
        let resolved = Self.resolvePath(path)
        guard var components = URLComponents(string: AppConfig.apiBase + resolved) else {
            throw APIError(status: 0, code: "bad_url", message: "Dirección no válida.")
        }
        let items = query.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url, url.scheme == "https" else {
            throw APIError(status: 0, code: "insecure", message: "Sólo se permiten conexiones seguras (HTTPS).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(AppConfig.appKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(AppConfig.appKey, forHTTPHeaderField: "X-App-Key")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue(AppConfig.version, forHTTPHeaderField: "X-App-Version")
        request.setValue(AppConfig.platform, forHTTPHeaderField: "X-Platform")
        request.setValue("splivmax-ios", forHTTPHeaderField: "X-Client")
        request.setValue(AppConfig.playerCapabilities, forHTTPHeaderField: "X-Player-Capabilities")
        if authorized, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method == .post {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        return request
    }

    /// Alias de rutas antiguas de la app → rutas reales de /v1.
    private static func resolvePath(_ path: String) -> String {
        // Solo /titles/{id} → /title/{id}. NO reescribir /titles/{id}/comments (provocaba 404).
        if path.hasPrefix("/titles/") {
            let rest = String(path.dropFirst("/titles/".count))
            if !rest.contains("/") {
                return "/title/" + rest
            }
        }
        if path == "/my-list" { return "/favorites" }
        if path == "/playback/progress" { return "/playback/progress" }
        return path
    }

    private func handle<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> (data: T, meta: PageMeta?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            do {
                return try decodeSuccess(data, as: T.self)
            } catch {
                #if DEBUG
                print("[API] No se pudo decodificar \(T.self):", error)
                if let raw = String(data: data.prefix(400), encoding: .utf8) { print(raw) }
                #endif
                throw APIError(status: status, code: "decode", message: "No pudimos leer la respuesta del servidor. Actualiza la app o inténtalo más tarde.")
            }
        }
        let error = parseError(data: data, status: status)
        if ["token_invalid", "profile_setup", "profile_required", "maintenance"].contains(error.code) {
            NotificationCenter.default.post(name: .apiSessionEvent, object: nil, userInfo: ["error": error])
        }
        throw error
    }

    private func decodeSuccess<T: Decodable>(_ data: Data, as type: T.Type) throws -> (data: T, meta: PageMeta?) {
        let meta = (try? decoder.decode(MetaEnvelope.self, from: data).meta)
        if let envelope = try? decoder.decode(Envelope<T>.self, from: data) {
            return (envelope.data, envelope.meta ?? meta)
        }
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = root["data"] {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                if let value = try? decoder.decode(T.self, from: nestedData) {
                    return (value, meta)
                }
            }
            if let items = root["items"] {
                let itemsData = try JSONSerialization.data(withJSONObject: items)
                if let value = try? decoder.decode(T.self, from: itemsData) {
                    return (value, meta)
                }
            }
            if let item = root["item"] {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                if let value = try? decoder.decode(T.self, from: itemData) {
                    return (value, meta)
                }
            }
        }
        let value = try decoder.decode(T.self, from: data)
        return (value, meta)
    }

    private func parseError(data: Data, status: Int) -> APIError {
        if let body = try? decoder.decode(ErrorEnvelope.self, from: data).error {
            return APIError(status: status, code: body.code, message: body.message, fields: body.fields)
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = root["error"] as? [String: Any] {
                return APIError(
                    status: status,
                    code: (err["code"] as? String) ?? "http_\(status)",
                    message: (err["message"] as? String) ?? "No se pudo completar la solicitud.",
                    fields: (err["fields"] as? [String: String]) ?? [:]
                )
            }
            if let message = root["error"] as? String {
                return APIError(status: status, code: "http_\(status)", message: message)
            }
        }
        if status >= 500 {
            return APIError(status: status, code: "server", message: "El servidor no responde en este momento. Inténtalo en unos minutos.")
        }
        return APIError(status: status, code: "http_\(status)", message: "No se pudo completar la solicitud (\(status)).")
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(url.code)
    }
}

private struct MetaEnvelope: Decodable {
    let meta: PageMeta?
}
