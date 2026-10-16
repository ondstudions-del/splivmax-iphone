import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var data: HomeData?
    @Published private(set) var error: APIError?
    @Published private(set) var loading = false
    private var loadedVersion = -1

    func load(version: Int, force: Bool = false) async {
        guard force || loadedVersion != version || data == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let home: HomeData = try await APIClient.shared.send(.get, "/home")
            data = home
            error = nil
            loadedVersion = version
            let posters = home.sections.prefix(2).flatMap { $0.items.prefix(6) }.compactMap(\.tallImage)
            ImagePipeline.shared.prefetch(posters, maxPixel: 360)
        } catch is CancellationError {
        } catch {
            let e = APIError.from(error)
            // Los 409 de perfil los resuelve la sesión; no se muestran como error.
            if !["profile_setup", "profile_required"].contains(e.code) { self.error = e }
        }
    }
}

struct HomeView: View {
    let openTab: (AppTab) -> Void
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @StateObject private var model = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let data = model.data {
                    if let hero = data.hero {
                        HeroCard(hero: hero)
                    } else {
                        WelcomeCard(openTab: openTab)
                    }
                    if !data.continueItems.isEmpty {
                        ContinueRow(items: data.continueItems)
                    }
                    ForEach(data.sections) { section in
                        if let genre = section.genre {
                            VStack(alignment: .leading, spacing: 0) {
                                TitleRow(title: section.title, items: section.items)
                                NavigationLink(value: Route.genre(slug: genre, name: section.title, type: nil)) {
                                    HStack(spacing: 4) {
                                        Text("Ver todo")
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.accent2)
                                    .padding(.horizontal, Theme.gutter)
                                    .padding(.top, 8)
                                }
                            }
                        } else {
                            TitleRow(title: section.title, items: section.items)
                        }
                    }
                    if data.sections.isEmpty && data.hero == nil {
                        EmptyStateView(icon: "film.stack", title: "Muy pronto", message: "Estamos preparando el catálogo. Vuelve en unos minutos.")
                    }
                    CreditsFooter()
                } else if model.error == nil {
                    SkeletonBlock(cornerRadius: Theme.radiusLarge)
                        .frame(height: min(Layout.screenWidth * 4 / 3, Layout.screenHeight * 0.74) - 24)
                        .padding(.horizontal, Theme.gutter)
                    SkeletonRow()
                    SkeletonRow()
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .overlay {
            if let error = model.error, model.data == nil {
                ErrorStateView(error: error) { Task { await model.load(version: session.contentVersion, force: true) } }
            }
        }
        .refreshable {
            await model.load(version: session.contentVersion, force: true)
            await session.refreshMe()
        }
        .safeAreaInset(edge: .top, spacing: 0) { HomeHeader() }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: session.contentVersion) {
            await model.load(version: session.contentVersion)
        }
    }
}

/// Cabecera de la web móvil: logo a la izquierda, avisos y perfil a la derecha, degradado negro → transparente.
private struct HomeHeader: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            LogoTitle(size: 26)
            Spacer()
            if session.isLoggedIn {
                NavigationLink(value: Route.notifications) {
                    Image(systemName: "bell")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .overlay(alignment: .topTrailing) {
                            if session.unread > 0 {
                                Text(session.unread > 9 ? "9+" : "\(session.unread)")
                                    .font(.system(size: 9.5, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Theme.bad, in: Capsule())
                                    .offset(x: 2, y: 2)
                            }
                        }
                }
                .accessibilityLabel(Text(session.unread > 0 ? "Notificaciones, \(session.unread) sin leer" : "Notificaciones"))
            } else {
                Button("Entrar") { _ = session.requireLogin() }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.gradient, in: Capsule())
            }
        }
        .padding(.horizontal, Theme.gutter + 2)
        .frame(height: 52)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .padding(.bottom, -18)
        )
    }
}

/// Destacado en tarjeta 3:4 (como .hero en móvil).
struct HeroCard: View {
    let hero: HeroItem
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @State private var appeared = false

    private var card: TitleCard { hero.card }

    var body: some View {
        let width = Layout.screenWidth - Theme.gutter * 2
        let height = min(width * 4 / 3, Layout.screenHeight * 0.74)

        ZStack(alignment: .bottom) {
            NavigationLink(value: Route.title(card)) {
                RemoteImage(card.wideImage, maxPixel: 1100)
                    .scaleEffect(appeared ? 1 : 1.06)
                    .animation(.easeOut(duration: 1.2), value: appeared)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Ver ficha de \(card.title)"))

            Theme.heroShade.allowsHitTesting(false)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: card.isSeries ? "tv" : "film")
                    Text(card.isSeries ? "SERIE DESTACADA" : "PELÍCULA DESTACADA")
                }
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.2)
                .foregroundColor(Theme.accent2)

                Text(card.title)
                    .font(.system(size: min(38, max(27, width * 0.085)), weight: .black))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

                heroMeta

                HStack(spacing: 8) {
                    Button { play() } label: {
                        Label(card.isUpcoming ? "Próximamente" : "Reproducir", systemImage: card.isUpcoming ? "clock" : "play.fill")
                    }
                    .buttonStyle(WhiteButtonStyle())
                    .disabled(card.isUpcoming || !card.playable)

                    if session.isLoggedIn {
                        let fav = session.isFavorite(card.id, fallback: false)
                        Button {
                            Task { await session.toggleFavorite(card.id, current: fav) }
                        } label: {
                            Image(systemName: fav ? "checkmark" : "plus")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityLabel(Text(fav ? "Quitar de Mi lista" : "Añadir a Mi lista"))
                    }

                    NavigationLink(value: Route.title(card)) {
                        Image(systemName: "info.circle")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel(Text("Más información"))
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.easeOut(duration: 0.55).delay(0.1), value: appeared)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 25, y: 20)
        .padding(.horizontal, Theme.gutter)
        .onAppear { appeared = true }
    }

    private var heroMeta: some View {
        HStack(spacing: 8) {
            if let y = card.year { Text(String(y)) }
            if let r = card.ratingText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundColor(Theme.premium)
                    Text(r)
                }
            }
            if let d = card.durationText { Text(d) }
            if let s = card.seasonsText { Text(s) }
            ForEach(Array(card.genres.prefix(2).enumerated()), id: \.offset) { pair in
                if pair.offset > 0 { Text("•").foregroundColor(Theme.muted) }
                Text(pair.element.name)
            }
            if card.isPremium { PremiumBadge(small: true) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Theme.text2)
        .lineLimit(1)
    }

    private func play() {
        guard session.requireLogin() else { return }
        player.play(titleId: card.id, title: card.title)
    }
}

private struct WelcomeCard: View {
    let openTab: (AppTab) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image("LogoMark").resizable().scaledToFit().frame(width: 72, height: 72)
            Text("Bienvenido a SPLIVMAX")
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.white)
            Text("Películas y series en un solo lugar.")
                .foregroundColor(Theme.text2)
            Button("Explorar películas") { openTab(.movies) }
                .buttonStyle(PrimaryButtonStyle(fullWidth: false))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(
            RadialGradient(colors: [Theme.accent.opacity(0.35), Theme.surface], center: .top, startRadius: 10, endRadius: 400),
            in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
        )
        .padding(.horizontal, Theme.gutter)
    }
}

struct ContinueRow: View {
    let items: [ContinueItem]
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Continuar viendo")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            guard session.requireLogin() else { return }
                            player.play(titleId: item.title.id, episodeId: item.episode?.id, title: item.title.title)
                        } label: {
                            ContinueCard(item: item)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(Text("Continuar \(item.title.title)"))
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }
}

struct CreditsFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            LogoTitle(size: 20).opacity(0.85)
            HStack(spacing: 5) {
                Text("Creado por").foregroundColor(Theme.muted)
                Text("OND-S").fontWeight(.heavy).foregroundStyle(Theme.gradient)
            }
            .font(.system(size: 12.5, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
