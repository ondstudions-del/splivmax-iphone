import SwiftUI

// MARK: - Mi lista

struct MyListView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var items: [TitleCard] = []
    @State private var loaded = false
    @State private var error: APIError?

    private var visible: [TitleCard] {
        items.filter { session.isFavorite($0.id, fallback: true) }
    }

    var body: some View {
        Group {
            if !session.isLoggedIn {
                LoginPrompt(icon: "heart", message: "Inicia sesión para guardar películas y series en tu lista.")
            } else if let error, items.isEmpty {
                ErrorStateView(error: error) { Task { await load() } }
            } else if !loaded {
                LoadingView()
            } else if visible.isEmpty {
                EmptyStateView(icon: "heart", title: "Tu lista está vacía",
                               message: "Toca el corazón en cualquier título para guardarlo aquí y verlo después.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    PosterGrid(items: visible).padding(.vertical, 12)
                }
            }
        }
        .screenBackground()
        .navigationTitle("Mi lista")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard session.isLoggedIn else { return }
        do {
            items = try await APIClient.shared.send(.get, "/my-list")
            session.replaceFavorites(ids: items.map(\.id))
            ImagePipeline.shared.prefetch(items.prefix(24).compactMap(\.tallImage), maxPixel: 360)
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
        loaded = true
    }
}

// MARK: - Historial y continuar viendo

@MainActor
final class HistoryModel: ObservableObject {
    @Published var continueItems: [ContinueItem] = []
    @Published var items: [HistoryItem] = []
    @Published var enabled = true
    @Published var loaded = false
    @Published var error: APIError?
    private var page = 1
    private var pages = 1
    private var loading = false

    func load(reset: Bool = true) async {
        if loading || (!reset && page >= pages) { return }
        loading = true
        defer { loading = false }
        let next = reset ? 1 : page + 1
        if reset {
            continueItems = (try? await APIClient.shared.send(.get, "/continue", as: [ContinueItem].self)) ?? continueItems
        }
        do {
            let (list, meta) = try await APIClient.shared.sendPage(.get, "/history", query: ["page": String(next)], as: [HistoryItem].self)
            enabled = meta?.enabled ?? true
            items = reset ? list : items + list
            page = meta?.page ?? next
            pages = meta?.pages ?? 1
            error = nil
        } catch {
            if items.isEmpty { self.error = APIError.from(error) }
        }
        loaded = true
    }
}

struct HistoryView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @StateObject private var model = HistoryModel()

    var body: some View {
        Group {
            if !session.isLoggedIn {
                LoginPrompt(icon: "clock.arrow.circlepath", message: "Inicia sesión para ver tu historial y continuar donde lo dejaste.")
            } else if let error = model.error, model.items.isEmpty, model.continueItems.isEmpty {
                ErrorStateView(error: error) { Task { await model.load() } }
            } else if !model.loaded {
                LoadingView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !model.continueItems.isEmpty {
                            ContinueRow(items: model.continueItems)
                        }
                        historySection
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .screenBackground()
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: player.closedCount) { _ in Task { await model.load() } }
    }

    @ViewBuilder
    private var historySection: some View {
        if !model.enabled {
            VStack(spacing: 12) {
                InlineNotice(message: "Tu plan actual no incluye el historial de reproducción.", icon: "lock.fill", color: Theme.warn)
                NavigationLink(value: Route.plans) { Text("Ver planes") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, Theme.gutter)
        } else if model.items.isEmpty {
            EmptyStateView(icon: "clock", title: "Aún no has visto nada", message: "Lo que reproduzcas aparecerá aquí.")
        } else {
            SectionTitle("Visto recientemente")
            ForEach(model.items) { item in
                NavigationLink(value: Route.title(item.title)) {
                    HistoryRow(item: item)
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, Theme.gutter)
                .onAppear {
                    if item.id == model.items.last?.id { Task { await model.load(reset: false) } }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(item.episode?.thumbnail ?? item.title.wideImage, maxPixel: 360)
                .frame(width: 124, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                if let ep = item.episode {
                    Text("\(ep.code) · \(ep.title)")
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.text2)
                        .lineLimit(1)
                }
                if let when = ISODate.relative(item.watchedAt) {
                    Text(when).font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.muted)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Notificaciones

struct NotificationsView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var items: [AppNotification] = []
    @State private var loaded = false
    @State private var error: APIError?
    @State private var link: WebLink?

    var body: some View {
        Group {
            if !session.isLoggedIn {
                LoginPrompt(icon: "bell", message: "Inicia sesión para recibir avisos de estrenos y de tu cuenta.")
            } else if let error, items.isEmpty {
                ErrorStateView(error: error) { Task { await load() } }
            } else if !loaded {
                LoadingView()
            } else if items.isEmpty {
                EmptyStateView(icon: "bell.slash", title: "Sin notificaciones", message: "Te avisaremos de planes, respuestas de soporte y estrenos destacados.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { n in
                        row(n).listRowBackground(n.read ? Theme.surface : Theme.surface2)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .screenBackground()
        .navigationTitle("Notificaciones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if items.contains(where: { !$0.read }) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Marcar leídas") { Task { await markRead() } }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $link) { SafariView(url: $0.url).ignoresSafeArea() }
        .onDisappear {
            if items.contains(where: { !$0.read }) { Task { await markRead() } }
        }
    }

    @ViewBuilder
    private func row(_ n: AppNotification) -> some View {
        let label = NotificationRow(notification: n)
        if let titleId = n.titleId {
            NavigationLink(value: Route.titleId(titleId)) { label }
        } else if (n.category ?? "").lowercased() == "plan" || linkPath(n.link).contains("/planes") {
            NavigationLink(value: Route.plans) { label }
        } else if (n.category ?? "").lowercased() == "support" {
            NavigationLink(value: Route.help) { label }
        } else if let raw = n.link, let url = URL(string: raw), url.scheme == "https", AppConfig.billingMode == .direct || !isBillingLink(url) {
            Button { link = WebLink(url: url) } label: { label }
        } else {
            label
        }
    }

    private func linkPath(_ link: String?) -> String {
        guard let link, let url = URL(string: link) else { return "" }
        return url.path.lowercased()
    }

    private func isBillingLink(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return ["/planes", "/pagos", "/pago", "/billetera", "/checkout", "/suscripcion"].contains { path.contains($0) }
    }

    private func load() async {
        guard session.isLoggedIn else { return }
        do {
            let (list, meta) = try await APIClient.shared.sendPage(.get, "/notifications", as: [AppNotification].self)
            items = list
            session.unread = meta?.unread ?? list.filter { !$0.read }.count
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
        loaded = true
    }

    private func markRead() async {
        let _: [String: Bool]? = try? await APIClient.shared.send(.post, "/notifications/read")
        for i in items.indices { items[i].read = true }
        session.unread = 0
    }
}

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(notification.read ? Theme.surface2 : Theme.accent2.opacity(0.22))
                    .frame(width: 36, height: 36)
                Image(systemName: notification.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(notification.read ? Theme.muted : Theme.accent2)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(notification.title)
                        .font(.system(size: 15, weight: notification.read ? .medium : .bold))
                        .foregroundColor(Theme.text)
                    if !notification.read {
                        Circle().fill(Theme.accent2).frame(width: 7, height: 7)
                    }
                }
                if !notification.body.isEmpty {
                    Text(notification.body).font(.system(size: 13.5)).foregroundColor(Theme.text2)
                }
                if let when = ISODate.relative(notification.createdAt) {
                    Text(when).font(.system(size: 11.5)).foregroundColor(Theme.muted)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Invitación a iniciar sesión

struct LoginPrompt: View {
    let icon: String
    let message: String
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        EmptyStateView(icon: icon, title: "Inicia sesión", message: message, actionTitle: "Iniciar sesión") {
            _ = session.requireLogin(.login)
        }
        .frame(maxHeight: .infinity)
    }
}
