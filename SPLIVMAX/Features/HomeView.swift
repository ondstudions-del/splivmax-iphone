import SwiftUI
import AVKit

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var data: HomeData?
    @Published private(set) var error: APIError?
    @Published private(set) var loading = false
    private var loadedVersion = -1

    func load(version: Int, force: Bool = false) async {
        guard force || loadedVersion != version || data == nil else { return }
        let showSpinner = data == nil
        if showSpinner { loading = true }
        defer { loading = false }
        do {
            let home: HomeData = try await APIClient.shared.send(.get, "/home")
            data = home
            error = nil
            loadedVersion = version
            prefetchImages(home)
        } catch is CancellationError {
        } catch {
            let e = APIError.from(error)
            if data == nil, !["profile_setup", "profile_required"].contains(e.code) { self.error = e }
        }
    }

    private func prefetchImages(_ home: HomeData) {
        var urls: [URL] = []
        if let hero = home.hero {
            if let u = hero.card.wideImage { urls.append(u) }
            if let u = hero.card.tallImage { urls.append(u) }
        }
        for item in home.continueItems.prefix(8) {
            if let u = item.episode?.thumbnail ?? item.title.wideImage { urls.append(u) }
        }
        for section in home.sections.prefix(5) {
            for item in section.items.prefix(10) {
                if let u = item.tallImage { urls.append(u) }
            }
        }
        ImagePipeline.shared.prefetch(urls, maxPixel: 480)
        if let heroURL = home.hero?.card.wideImage {
            Task { _ = await ImagePipeline.shared.load(heroURL, maxPixel: 1100) }
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
            LazyVStack(alignment: .leading, spacing: 28) {
                if let data = model.data {
                    if let hero = data.hero {
                        HeroCard(hero: hero)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        WelcomeCard(openTab: openTab)
                    }
                    if !data.continueItems.isEmpty {
                        ContinueRow(items: data.continueItems)
                    }
                    ForEach(Array(data.sections.enumerated()), id: \.element.id) { index, section in
                        Group {
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
                        .opacity(1)
                        .animation(.easeOut(duration: 0.35).delay(0.04 * Double(min(index, 6))), value: data.sections.count)
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
            .padding(.bottom, 28)
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

/// Cabecera de la web móvil: logo a la izquierda, avisos y perfil a la derecha.
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
                        .background(.ultraThinMaterial.opacity(0.35), in: Circle())
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
            LinearGradient(colors: [Color.black.opacity(0.88), Color.black.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .padding(.bottom, -18)
        )
    }
}

/// Destacado: póster/backdrop siempre visible; el vídeo de preview se funde encima al estar listo.
struct HeroCard: View {
    let hero: HeroItem
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @State private var appeared = false
    @State private var videoReady = false

    private var card: TitleCard { hero.card }

    var body: some View {
        let width = Layout.screenWidth - Theme.gutter * 2
        let height = min(width * 4 / 3, Layout.screenHeight * 0.74)

        ZStack(alignment: .bottom) {
            NavigationLink(value: Route.title(card)) {
                ZStack {
                    RemoteImage(card.wideImage ?? card.tallImage, maxPixel: 1100)
                    if let video = hero.heroVideo, let url = video.url {
                        HeroPreviewPlayer(url: url, isReady: $videoReady)
                            .opacity(videoReady ? 1 : 0)
                            .animation(.easeInOut(duration: 0.55), value: videoReady)
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(appeared ? 1 : 1.04)
                .animation(.easeOut(duration: 1.1), value: appeared)
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
                        let fav = session.isFavorite(card.id, fallback: hero.favorite)
                        Button {
                            Task { await session.toggleFavorite(card.id, current: fav) }
                        } label: {
                            Image(systemName: fav ? "checkmark" : "plus")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(GlassButtonStyle(accent: fav))
                        .accessibilityLabel(Text(fav ? "Guardado en Mi lista" : "Añadir a Mi lista"))
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: fav)
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
            .animation(.easeOut(duration: 0.55).delay(0.08), value: appeared)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
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

/// Vídeo silencioso en bucle para el hero; avisa cuando el primer fotograma está listo.
private struct HeroPreviewPlayer: UIViewRepresentable {
    let url: URL
    @Binding var isReady: Bool

    func makeUIView(context: Context) -> HeroPreviewUIView {
        let view = HeroPreviewUIView()
        view.onReady = { isReady = true }
        view.play(url: url)
        return view
    }

    func updateUIView(_ uiView: HeroPreviewUIView, context: Context) {
        if uiView.currentURL != url {
            isReady = false
            uiView.onReady = { isReady = true }
            uiView.play(url: url)
        }
    }

    static func dismantleUIView(_ uiView: HeroPreviewUIView, coordinator: ()) {
        uiView.stop()
    }
}

private final class HeroPreviewUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var looper: AVPlayerLooper?
    private var queue: AVQueuePlayer?
    private var readyObs: NSKeyValueObservation?
    var currentURL: URL?
    var onReady: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func play(url: URL) {
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(playerItem: item)
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: queue, templateItem: item)
        self.queue = queue
        player = queue
        playerLayer.player = queue
        readyObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                self?.onReady?()
                queue.play()
            }
        }
        queue.play()
    }

    func stop() {
        readyObs = nil
        looper?.disableLooping()
        looper = nil
        queue?.pause()
        queue?.removeAllItems()
        queue = nil
        player = nil
        playerLayer.player = nil
        currentURL = nil
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
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Continuar viendo")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            guard session.requireLogin() else { return }
                            player.play(
                                titleId: item.title.id,
                                episodeId: item.episode?.id,
                                title: item.title.title
                            )
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
