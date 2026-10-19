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
    /// La elección de perfil es obligatoria al abrir la app: sin botón «Cancelar».
    @Published private(set) var profileChoiceRequired = false
    /// Cambia al entrar, salir o cambiar de perfil: las pantallas recargan su contenido.
    @Published private(set) var contentVersion = 0
    @Published private var favoriteOverrides: [String: Bool] = [:]

    let api = APIClient.shared
    private var bag = Set<AnyCancellable>()
    private static let meCacheKey = "spx.me.v1"
    private static let chooseProfileKey = "spx.profiles.choose"
    private static let favoritesKeyPrefix = "spx.favorites."

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
                loadFavoriteCache()
                phase = .ready
            }
            await refreshMe()
            if phase == .launching {
                phase = user == nil ? .guest : .ready
            }
            // Al cerrar y volver a abrir la app: pedir perfil (no al salir a segundo plano).
            if phase == .ready, isLoggedIn {
                askWhoIsWatching()
            }
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
            await loadProfiles()
            await syncFavoritesFromServer()
            if profilesData?.setupPending == true {
                phase = .profileSetup
            } else if me.profile == nil && profile == nil {
                // Sin perfil activo: hay que elegir. No forzar si ya hay uno en memoria
                // ni si estamos sin red (Offline / perfil reciente).
                if NetworkMonitor.shared.isOnline {
                    profileChoiceRequired = true
                    phase = .profileChoice
                } else if phase == .launching || phase == .guest {
                    phase = .ready
                }
            } else if phase == .launching || phase == .guest || phase == .profileSetup {
                phase = .ready
            }
        } catch let error as APIError where error.code == "token_invalid" {
            // handle(event:) ya cerró la sesión.
        } catch {
            if phase == .launching { phase = user == nil ? .guest : .ready }
        }
    }

    private func apply(me: MeData) {
        let scope = me.profile?.id ?? me.user.id
        api.setCacheScope(scope)
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
        api.setCacheScope(session.profile?.id ?? user.id)
        favoriteOverrides = [:]
        self.user = user
        profile = session.profile
        loadFavoriteCache()
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
        api.setCacheScope("anon")
        UserDefaults.standard.removeObject(forKey: Self.meCacheKey)
        user = nil
        profile = nil
        profilesData = nil
        subscription = nil
        unread = 0
        favoriteOverrides = [:]
        profileChoiceRequired = false
        UserDefaults.standard.removeObject(forKey: Self.chooseProfileKey)
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
            let data: ProfilesData = try await api.send(.get, "/profiles")
            profilesData = data
            UserDefaults.standard.set(Self.needsChoice(data.items), forKey: Self.chooseProfileKey)
        } catch {}
    }

    /// Solo se pregunta «¿Quién está viendo?» si hay algo que elegir: varios perfiles o alguno con PIN.
    private static func needsChoice(_ items: [Profile]) -> Bool {
        items.count > 1 || items.contains(where: \.locked)
    }

    private var profilesNeedChoice: Bool {
        if let data = profilesData { return Self.needsChoice(data.items) }
        return UserDefaults.standard.bool(forKey: Self.chooseProfileKey)
    }

    /// Selector de perfiles al abrir la app (cerrar y volver a entrar), no al salir a segundo plano.
    func askWhoIsWatching() {
        guard isLoggedIn, phase == .ready || phase == .profileChoice else { return }
        if !NetworkMonitor.shared.isOnline {
            return
        }
        if profilesNeedChoice {
            profileChoiceRequired = true
            phase = .profileChoice
            Task { await loadProfiles() }
        } else if profilesData == nil {
            Task {
                await loadProfiles()
                guard phase == .ready, NetworkMonitor.shared.isOnline, profilesNeedChoice else { return }
                profileChoiceRequired = true
                phase = .profileChoice
            }
        }
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
        api.setCacheScope(r.profile.id)
        profile = r.profile
        loadFavoriteCache()
        profileChoiceRequired = false
        phase = .ready
        contentVersion += 1
        await refreshMe()
        if profile != nil {
            profileChoiceRequired = false
            if phase == .profileChoice { phase = .ready }
        }
    }

    func switchProfile() async {
        profileChoiceRequired = false
        await loadProfiles()
        phase = .profileChoice
    }

    func cancelProfileChoice() {
        if profile != nil && !profileChoiceRequired { phase = .ready }
    }

    /// Fuerza volver al contenido (p. ej. offline con perfil ya activo).
    func forceReadyWithCurrentProfile() {
        guard profile != nil else { return }
        profileChoiceRequired = false
        phase = .ready
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

    func isFavorite(_ id: String, fallback: Bool = false) -> Bool {
        favoriteOverrides[id] ?? fallback
    }

    func toggleFavorite(_ id: String, current: Bool) async {
        guard requireLogin() else { return }
        let wanted = !current
        setFavoriteOverride(id, wanted)
        Haptics.tap()
        do {
            let r: FavoriteResponse = try await api.send(.post, "/my-list/\(id)", body: ["favorite": wanted])
            setFavoriteOverride(id, r.favorite)
            show(r.favorite ? "Añadido a Mi lista" : "Quitado de Mi lista", .success)
        } catch {
            setFavoriteOverride(id, current)
            show(APIError.from(error).message, .error)
        }
    }

    private func setFavoriteOverride(_ id: String, _ value: Bool) {
        var map = favoriteOverrides
        map[id] = value
        favoriteOverrides = map
        persistFavoriteCache()
    }

    private func favoritesStorageKey() -> String? {
        guard let pid = profile?.id ?? user?.id else { return nil }
        return Self.favoritesKeyPrefix + pid
    }

    private func loadFavoriteCache() {
        guard let key = favoritesStorageKey(),
              let ids = UserDefaults.standard.array(forKey: key) as? [String] else { return }
        var map = favoriteOverrides
        for id in ids { map[id] = true }
        // Reasignar para notificar a SwiftUI.
        favoriteOverrides = map
        objectWillChange.send()
    }

    private func persistFavoriteCache() {
        guard let key = favoritesStorageKey() else { return }
        let ids = favoriteOverrides.compactMap { $0.value ? $0.key : nil }.sorted()
        UserDefaults.standard.set(ids, forKey: key)
    }

    func replaceFavorites(ids: [String]) {
        var map: [String: Bool] = [:]
        for id in ids { map[id] = true }
        favoriteOverrides = map
        persistFavoriteCache()
    }

    private func syncFavoritesFromServer() async {
        guard api.token != nil else { return }
        do {
            let items: [TitleCard] = try await api.send(.get, "/my-list")
            replaceFavorites(ids: items.map(\.id))
        } catch {}
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
            // Ignorar si ya hay perfil activo, o si estamos offline (no bloquear Offline).
            if api.token != nil, phase != .profileChoice, profile == nil, NetworkMonitor.shared.isOnline {
                profileChoiceRequired = true
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
