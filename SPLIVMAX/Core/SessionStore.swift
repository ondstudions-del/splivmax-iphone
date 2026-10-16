import SwiftUI
import Combine

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    let message: String
    var kind: Kind = .info
}

enum AuthMode: Hashable { case login, register, forgot }

/// Estado global: sesión, perfil activo, plan, configuración del servidor y avisos.
@MainActor
final class SessionStore: ObservableObject {
    enum Phase: Equatable { case launching, guest, profileSetup, profileChoice, ready }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var user: User?
    @Published private(set) var profile: Profile?
    @Published private(set) var profilesData: ProfilesData?
    @Published private(set) var subscription: Subscription?
    @Published private(set) var config: ServerConfig?
    @Published var unread = 0
    @Published var loginPresented = false
    @Published var authMode: AuthMode = .login
    @Published var toast: Toast?
    @Published var maintenanceMessage: String?
    /// Cambia al entrar, salir o cambiar de perfil: las pantallas recargan su contenido.
    @Published private(set) var contentVersion = 0
    @Published private var favoriteOverrides: [String: Bool] = [:]

    let api = APIClient.shared
    private var bag = Set<AnyCancellable>()
    private static let meCacheKey = "spx.me.v1"

    init() {
        NotificationCenter.default.publisher(for: .apiSessionEvent)
            .compactMap { $0.userInfo?["error"] as? APIError }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in self?.handle(event: error) }
            .store(in: &bag)
    }

    var isLoggedIn: Bool { user != nil && api.token != nil }
    var isKids: Bool { profile?.kids ?? false }
    var profiles: [Profile] { profilesData?.items ?? [] }
    var registrationOpen: Bool { config?.features.registrationOpen ?? true }
    var minPassword: Int { config?.minPassword ?? 10 }

    // MARK: Arranque

    func bootstrap() async {
        async let configTask: Void = loadConfig()
        if let token = KeychainStore.string("token") {
            api.token = token
            if let cached = Self.cachedMe() {
                apply(me: cached)
                phase = .ready
            }
            await refreshMe()
            if phase == .launching { phase = user == nil ? .guest : .ready }
        } else {
            phase = .guest
        }
        await configTask
    }

    func loadConfig() async {
        do {
            let cfg: ServerConfig = try await api.send(.get, "/config", authorized: false)
            config = cfg
            maintenanceMessage = cfg.features.maintenance ? (cfg.features.maintenanceMessage ?? "Estamos haciendo mejoras. Vuelve en unos minutos.") : nil
        } catch {
            // Sin configuración la app sigue funcionando con los valores por defecto.
        }
    }

    func refreshMe() async {
        guard api.token != nil else { return }
        do {
            let me: MeData = try await api.send(.get, "/me")
            apply(me: me)
            Self.storeMe(me)
            if me.profile == nil {
                await loadProfiles()
                phase = (profilesData?.setupPending ?? false) ? .profileSetup : .profileChoice
            } else if phase == .launching || phase == .guest {
                phase = .ready
            }
        } catch let error as APIError where error.code == "token_invalid" {
            // handle(event:) ya cerró la sesión.
        } catch {
            if phase == .launching { phase = user == nil ? .guest : .ready }
        }
    }

    private func apply(me: MeData) {
        user = me.user
        if let p = me.profile { profile = p }
        subscription = me.subscription
        unread = me.unreadNotifications
    }

    // MARK: Inicio de sesión

    func login(email: String, password: String) async throws {
        let session: AuthSession = try await api.send(.post, "/auth/login", body: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "device_name": UIDevice.current.name,
        ], authorized: false)
        try await adopt(session)
    }

    /// Devuelve un mensaje si la cuenta necesita verificar el correo antes de entrar.
    func register(name: String, email: String, password: String) async throws -> String? {
        let session: AuthSession = try await api.send(.post, "/auth/register", body: [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "accept_terms": true,
            "device_name": UIDevice.current.name,
        ], authorized: false)
        if session.token == nil {
            return session.message ?? "Cuenta creada. Revisa tu correo para verificarla antes de iniciar sesión."
        }
        try await adopt(session)
        if let days = session.trialDays, days > 0 {
            show("¡Bienvenido! Tienes \(days) días de prueba gratuita.", .success)
        }
        return nil
    }

    func forgotPassword(email: String) async throws -> String {
        let r: MessageResponse = try await api.send(.post, "/auth/forgot", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)], authorized: false)
        return r.message ?? "Si el correo está registrado, recibirás un enlace para restablecer la contraseña."
    }

    private func adopt(_ session: AuthSession) async throws {
        guard let token = session.token, let user = session.user else {
            throw APIError(status: 0, code: "decode", message: "Respuesta inesperada del servidor.")
        }
        KeychainStore.set(token, for: "token")
        api.token = token
        api.clearCache()
        favoriteOverrides = [:]
        self.user = user
        profile = session.profile
        loginPresented = false
        if session.profileSetup == true {
            phase = .profileSetup
        } else if session.profileRequired == true {
            await loadProfiles()
            phase = .profileChoice
        } else {
            phase = .ready
            contentVersion += 1
        }
        await refreshMe()
    }

    func logout() async {
        if api.token != nil {
            let _: [String: Bool]? = try? await api.send(.post, "/auth/logout")
        }
        signOutLocally(message: "Cerraste sesión.")
    }

    func signOutLocally(message: String?) {
        KeychainStore.set(nil, for: "token")
        api.token = nil
        api.clearCache()
        UserDefaults.standard.removeObject(forKey: Self.meCacheKey)
        user = nil
        profile = nil
        profilesData = nil
        subscription = nil
        unread = 0
        favoriteOverrides = [:]
        phase = .guest
        contentVersion += 1
        if let message { show(message, .info) }
    }

    /// Para acciones que necesitan cuenta: abre el inicio de sesión si es invitado.
    func requireLogin(_ mode: AuthMode = .login) -> Bool {
        if isLoggedIn { return true }
        authMode = mode
        loginPresented = true
        return false
    }

    // MARK: Perfiles

    func loadProfiles() async {
        do {
            profilesData = try await api.send(.get, "/profiles")
        } catch {}
    }

    func completeSetup(name: String, avatar: String) async throws {
        let r: ProfileResponse = try await api.send(.post, "/profiles/setup", body: ["name": name, "avatar": avatar])
        profile = r.profile
        phase = .ready
        contentVersion += 1
        await refreshMe()
    }

    func select(profile id: String, pin: String?) async throws {
        var body: [String: Any] = [:]
        if let pin, !pin.isEmpty { body["pin"] = pin }
        let r: ProfileResponse = try await api.send(.post, "/profiles/\(id)/select", body: body)
        api.clearCache()
        favoriteOverrides = [:]
        profile = r.profile
        phase = .ready
        contentVersion += 1
        await refreshMe()
    }

    func switchProfile() async {
        await loadProfiles()
        phase = .profileChoice
    }

    func cancelProfileChoice() {
        if profile != nil { phase = .ready }
    }

    func saveProfile(id: String?, body: [String: Any]) async throws -> Profile {
        let r: ProfileResponse = try await api.send(.post, id.map { "/profiles/\($0)" } ?? "/profiles", body: body)
        await loadProfiles()
        if r.profile.id == profile?.id { profile = r.profile }
        return r.profile
    }

    func deleteProfile(id: String, pin: String?) async throws {
        var body: [String: Any] = [:]
        if let pin, !pin.isEmpty { body["pin"] = pin }
        let _: [String: Bool] = try await api.send(.post, "/profiles/\(id)/delete", body: body)
        await loadProfiles()
    }

    // MARK: Cuenta

    func updateUser(_ user: User) { self.user = user }

    func setSubscription(_ sub: Subscription?) {
        guard let sub else { return }
        subscription = sub
    }

    func deleteAccount(password: String, reason: String) async throws -> String {
        let r: MessageResponse = try await api.send(.post, "/me/delete", body: ["current_password": password, "reason": reason])
        signOutLocally(message: nil)
        return r.message ?? "Recibimos tu solicitud de eliminación."
    }

    // MARK: Mi lista

    func isFavorite(_ id: String, fallback: Bool) -> Bool {
        favoriteOverrides[id] ?? fallback
    }

    func toggleFavorite(_ id: String, current: Bool) async {
        guard requireLogin() else { return }
        let wanted = !current
        favoriteOverrides[id] = wanted
        Haptics.tap()
        do {
            let r: FavoriteResponse = try await api.send(.post, "/my-list/\(id)", body: ["favorite": wanted])
            favoriteOverrides[id] = r.favorite
            show(r.favorite ? "Añadido a Mi lista" : "Quitado de Mi lista", .success)
        } catch {
            favoriteOverrides[id] = current
            show(APIError.from(error).message, .error)
        }
    }

    // MARK: Avisos

    func show(_ message: String, _ kind: Toast.Kind = .info) {
        toast = Toast(message: message, kind: kind)
    }

    private func handle(event error: APIError) {
        switch error.code {
        case "token_invalid":
            if api.token != nil { signOutLocally(message: error.message) }
        case "profile_setup":
            if api.token != nil, phase != .profileSetup { phase = .profileSetup }
        case "profile_required":
            if api.token != nil, phase != .profileChoice {
                phase = .profileChoice
                Task { await loadProfiles() }
            }
        case "maintenance":
            maintenanceMessage = error.message
        default:
            break
        }
    }

    // MARK: Caché local (sólo datos visibles de la cuenta; nunca la contraseña ni el token)

    private static func storeMe(_ me: MeData) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(me) { UserDefaults.standard.set(data, forKey: meCacheKey) }
    }

    private static func cachedMe() -> MeData? {
        guard let data = UserDefaults.standard.data(forKey: meCacheKey) else { return nil }
        return try? APIClient.shared.decoder.decode(MeData.self, from: data)
    }
}
