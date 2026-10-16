import SwiftUI

/// Destinos de navegación compartidos por todas las pestañas.
enum Route: Hashable {
    case title(TitleCard)
    case titleId(String)
    case genre(slug: String, name: String, type: String?)
    case myList
    case history
    case notifications
    case plans
    case settings
    case devices
    case editAccount
    case manageProfiles
    case payments
    case help
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .title(let card): TitleDetailView(id: card.id, preview: card)
        case .titleId(let id): TitleDetailView(id: id, preview: nil)
        case .genre(let slug, let name, let type): GenreCatalogView(slug: slug, name: name, type: type)
        case .myList: MyListView()
        case .history: HistoryView()
        case .notifications: NotificationsView()
        case .plans: PlansView()
        case .settings: SettingsView()
        case .devices: DevicesView()
        case .editAccount: EditAccountView()
        case .manageProfiles: ManageProfilesView()
        case .payments: PaymentsView()
        case .help: HelpView()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var splashDone = false
    @State private var leftApp = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if splashDone {
                Group {
                    switch session.phase {
                    case .launching:
                        LoadingView(text: "Conectando…")
                    case .profileSetup:
                        ProfileSetupView()
                    case .profileChoice:
                        ProfilePickerView()
                    case .guest, .ready:
                        MainTabView()
                    }
                }
                .transition(.opacity)
            }

            if !splashDone {
                SplashView()
                    .transition(.opacity)
                    .zIndex(3)
            }

            if let message = session.maintenanceMessage, splashDone {
                MaintenanceView(message: message)
                    .transition(.opacity)
                    .zIndex(4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.phase)
        .overlay(alignment: .top) {
            if !network.isOnline && splashDone {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: network.isOnline)
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { session.toast = nil }
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_800_000_000)
                        if session.toast?.id == toast.id { session.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.toast)
        .sheet(isPresented: $session.loginPresented) {
            AuthSheet()
                .environmentObject(session)
        }
        .fullScreenCover(item: $player.request) { request in
            PlayerView(request: request)
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(network)
        }
        .task {
            Task { await session.bootstrap() }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.45)) { splashDone = true }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                leftApp = true
            case .active:
                // Al volver tras salir de la app se elige perfil, salvo si el reproductor sigue abierto (PiP, AirPlay).
                if leftApp && player.request == nil { session.askWhoIsWatching() }
                leftApp = false
                if session.isLoggedIn { Task { await session.refreshMe() } }
            default:
                break
            }
        }
        .onChange(of: network.isOnline) { online in
            if online, session.isLoggedIn { Task { await session.refreshMe() } }
        }
    }
}

// MARK: - Pestañas

enum AppTab: Hashable, CaseIterable {
    case home, series, movies, search, account
}

struct MainTabView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var tab: AppTab = .home
    @State private var visited: Set<AppTab> = [.home]
    @State private var paths: [AppTab: NavigationPath] = [:]

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { item in
                if visited.contains(item) {
                    NavigationStack(path: path(for: item)) {
                        root(item)
                            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                    }
                    .opacity(tab == item ? 1 : 0)
                    .allowsHitTesting(tab == item)
                    .accessibilityHidden(tab != item)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selection: tab, onSelect: select)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: session.contentVersion) { _ in
            paths = [:]
        }
    }

    @ViewBuilder
    private func root(_ item: AppTab) -> some View {
        switch item {
        case .home: HomeView(openTab: select)
        case .series: CatalogView(type: "series")
        case .movies: CatalogView(type: "movie")
        case .search: SearchView()
        case .account: AccountView()
        }
    }

    private func path(for item: AppTab) -> Binding<NavigationPath> {
        Binding(get: { paths[item] ?? NavigationPath() }, set: { paths[item] = $0 })
    }

    private func select(_ item: AppTab) {
        if item == tab {
            // Tocar la pestaña activa vuelve a su pantalla principal.
            if let current = paths[item], !current.isEmpty {
                withAnimation { paths[item] = NavigationPath() }
            }
            return
        }
        Haptics.select()
        visited.insert(item)
        tab = item
    }
}

/// Barra inferior de la web móvil (.tabbar): 5 accesos, fondo translúcido, icono activo en cian.
struct TabBar: View {
    let selection: AppTab
    let onSelect: (AppTab) -> Void
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            item(.home, "Inicio", "house", "house.fill")
            item(.series, "Series", "tv", "tv.fill")
            item(.movies, "Películas", "film", "film.fill")
            item(.search, "Buscar", "magnifyingglass", "magnifyingglass")
            accountItem
        }
        .padding(.top, 7)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.bg.opacity(0.86)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
        }
    }

    private func item(_ tab: AppTab, _ label: String, _ icon: String, _ filled: String) -> some View {
        let on = selection == tab
        return Button { onSelect(tab) } label: {
            VStack(spacing: 3) {
                Image(systemName: on ? filled : icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(on ? Theme.accent2 : Theme.muted)
                    .scaleEffect(on ? 1.06 : 1)
                    .offset(y: on ? -1 : 0)
                    .frame(height: 26)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(on ? .white : Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var accountItem: some View {
        let on = selection == .account
        let label = session.isLoggedIn ? "Perfil" : "Entrar"
        return Button { onSelect(.account) } label: {
            VStack(spacing: 3) {
                Group {
                    if session.isLoggedIn, let profile = session.profile {
                        AvatarView(url: profile.avatarUrl, size: 24, name: profile.name)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(on ? Theme.accent2 : .clear, lineWidth: 1.5))
                    } else {
                        Image(systemName: on ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundColor(on ? Theme.accent2 : Theme.muted)
                    }
                }
                .frame(height: 26)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(on ? .white : Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Estados globales

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("Sin conexión a internet")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.bad.opacity(0.92), in: Capsule())
        .padding(.top, 4)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct MaintenanceView: View {
    let message: String
    @EnvironmentObject private var session: SessionStore
    @State private var checking = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.35), .clear], center: .top, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LogoMark").resizable().scaledToFit().frame(width: 84, height: 84)
                Text("Estamos en mantenimiento")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(Theme.text)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.text2)
                    .multilineTextAlignment(.center)
                Button {
                    Task {
                        checking = true
                        await session.loadConfig()
                        checking = false
                    }
                } label: {
                    if checking { ProgressView().tint(.white) } else { Text("Reintentar") }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                .disabled(checking)
            }
            .padding(32)
        }
    }
}
