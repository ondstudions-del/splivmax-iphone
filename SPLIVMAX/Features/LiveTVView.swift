import SwiftUI
import Combine

/// El aviso +18 se confirma una vez por sesión de la app.
enum LiveAdultGate {
    static var confirmed = false
    static let title = "Contenido para adultos (+18)"
    static let message = "Este canal contiene material explícito para mayores de 18 años. ¿Confirmas que eres mayor de edad?"
}

// MARK: - Pestaña Canales

@MainActor
final class ChannelsModel: ObservableObject {
    @Published private(set) var data: LiveTvData?
    @Published private(set) var error: APIError?
    @Published private(set) var loading = false
    private var loadedKey = ""

    func loadIfNeeded(key: String) async {
        if loadedKey != key || (data == nil && error == nil) {
            loadedKey = key
            await reload()
        }
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        do {
            let d: LiveTvData = try await APIClient.shared.send(.get, "/channels")
            data = d
            error = nil
        } catch is CancellationError {
        } catch {
            let e = APIError.from(error)
            if data == nil, !["profile_setup", "profile_required"].contains(e.code) { self.error = e }
        }
        loading = false
    }
}

struct LiveLaunch: Identifiable {
    let id = UUID()
    let channels: [LiveChannel]
    let index: Int
}

/// Canales de TV en vivo (M3U8), numerados desde el 100. Solo existen en la app; la web no los muestra.
struct ChannelsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model = ChannelsModel()
    @State private var query = ""
    @State private var category: String?
    @State private var launch: LiveLaunch?
    @State private var adultPending: LiveChannel?

    var body: some View {
        content
            .screenBackground()
            .navigationTitle("Canales")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar canal por nombre o número")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if session.isLoggedIn {
                        Button { Task { await model.reload() } } label: {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Theme.text)
                        }
                        .accessibilityLabel(Text("Actualizar"))
                    }
                }
            }
            .task(id: "\(session.contentVersion)-\(session.isLoggedIn)") {
                guard session.isLoggedIn else { return }
                await model.loadIfNeeded(key: "\(session.contentVersion)")
            }
            .fullScreenCover(item: $launch) { item in
                LivePlayerView(launch: item)
                    .environmentObject(session)
            }
            .alert(LiveAdultGate.title, isPresented: Binding(get: { adultPending != nil }, set: { if !$0 { adultPending = nil } })) {
                Button("Cancelar", role: .cancel) { adultPending = nil }
                Button("Soy mayor de 18") {
                    LiveAdultGate.confirmed = true
                    if let channel = adultPending, let data = model.data { play(channel, data) }
                    adultPending = nil
                }
            } message: {
                Text(LiveAdultGate.message)
            }
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            EmptyStateView(icon: "play.tv", title: "Canales en vivo",
                           message: "Inicia sesión para ver canales en directo de varios países.",
                           actionTitle: "Iniciar sesión") { _ = session.requireLogin() }
                .frame(maxHeight: .infinity)
        } else if let data = model.data {
            if data.channels.isEmpty {
                EmptyStateView(icon: "play.tv", title: "Sin canales",
                               message: data.enabled ? "Aún no hay canales disponibles para este perfil." : "Los canales no están disponibles ahora.",
                               actionTitle: "Actualizar") { Task { await model.reload() } }
                    .frame(maxHeight: .infinity)
            } else {
                list(data)
            }
        } else if let error = model.error {
            ErrorStateView(error: error) { Task { await model.reload() } }
        } else {
            LoadingView(text: "Cargando canales…")
        }
    }

    private func list(_ data: LiveTvData) -> some View {
        let items = visible(data)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section {
                    if !data.canPlay { paywall(data) }
                    if items.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "Sin resultados",
                                       message: "Busca por el nombre del canal o por su número (por ejemplo 105).")
                    }
                    ForEach(items) { channel in
                        Button { openChannel(channel, data) } label: { ChannelRow(channel: channel) }
                            .buttonStyle(PressableStyle())
                            .padding(.horizontal, Theme.gutter)
                    }
                } header: {
                    categoryBar(data)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.reload() }
    }

    private func categoryBar(_ data: LiveTvData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(label: "Todos · \(data.channels.count)", selected: category == nil) { category = nil }
                ForEach(data.categories) { cat in
                    ChipButton(label: cat.adult ? "\(cat.name) · +18" : cat.name, selected: category == cat.id) { category = cat.id }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
        }
        .background(Theme.bg.opacity(0.96))
    }

    private func paywall(_ data: LiveTvData) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundColor(Theme.accent2)
            Text(data.message ?? "Necesitas un plan activo para ver los canales.")
                .font(.system(size: 13.5))
                .foregroundColor(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(value: Route.plans) {
                Text("Ver planes").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: false))
        }
        .panel(padding: 14)
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 4)
    }

    private func visible(_ data: LiveTvData) -> [LiveChannel] {
        var list = data.channels
        if let category, let cat = data.categories.first(where: { $0.id == category }) {
            list = cat.channels.sorted { $0.number < $1.number }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        if q.allSatisfy(\.isNumber) {
            return list.filter { String($0.number).hasPrefix(q) }
        }
        return list.filter { "\($0.name) \($0.category)".lowercased().contains(q) }
    }

    private func openChannel(_ channel: LiveChannel, _ data: LiveTvData) {
        guard data.canPlay else {
            session.show(data.message ?? "Necesitas un plan activo para ver los canales.", .error)
            return
        }
        if channel.adult && !LiveAdultGate.confirmed {
            adultPending = channel
            return
        }
        play(channel, data)
    }

    private func play(_ channel: LiveChannel, _ data: LiveTvData) {
        let index = data.channels.firstIndex(where: { $0.id == channel.id }) ?? 0
        Haptics.tap()
        launch = LiveLaunch(channels: data.channels, index: index)
    }
}

struct ChannelRow: View {
    let channel: LiveChannel

    var body: some View {
        HStack(spacing: 12) {
            ChannelNumberTag(number: channel.number)
            ChannelLogo(url: channel.logo, width: 72, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(channel.epgNow ?? channel.category)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if channel.adult { LiveBadge(text: "+18", dark: true) }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(Theme.accent2.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .frame(height: 70)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Canal \(channel.number), \(channel.name)"))
        .accessibilityAddTraits(.isButton)
    }
}

struct ChannelNumberTag: View {
    let number: Int
    var width: CGFloat = 54
    var fontSize: CGFloat = 18

    var body: some View {
        Text(String(number))
            .font(.system(size: fontSize, weight: .black).monospacedDigit())
            .foregroundStyle(Theme.gradient)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(0.45), lineWidth: 1))
    }
}

struct ChannelLogo: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RemoteImage(url, maxPixel: 240, contentMode: .fit, placeholderIcon: "play.tv")
            .padding(5)
            .frame(width: width, height: height)
            .background(Color(hex: 0x0B0F1E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LiveBadge: View {
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .heavy))
            .kerning(0.4)
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(dark ? Color.black.opacity(0.7) : Theme.bad, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(dark ? Color.white.opacity(0.24) : .clear, lineWidth: 1))
    }
}

// MARK: - Reproductor

/// Zapping en directo con VLC (los enlaces son HLS por http). La URL se pide al servidor justo antes
/// de abrir cada canal porque el token del enlace caduca.
@MainActor
final class LivePlayerModel: ObservableObject {
    struct AdultPrompt: Equatable {
        let index: Int
        let direction: Int
    }

    let channels: [LiveChannel]
    let engine = VLCPlayerEngine()
    @Published private(set) var index: Int
    @Published private(set) var loading = true
    @Published private(set) var buffering = false
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    @Published private(set) var stream: LiveStream?
    @Published private(set) var adultPrompt: AdultPrompt?

    private var generation = 0
    private var retries = 0
    private var closed = false
    private var tuneTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var openedAt: Date?
    private var lastTime: Double = 0
    private var lastProgress = Date.distantPast
    private var bag = Set<AnyCancellable>()

    var channel: LiveChannel { channels[index] }
    var showSpinner: Bool { error == nil && (loading || (buffering && !playing)) }

    init(launch: LiveLaunch) {
        channels = launch.channels
        index = min(max(0, launch.index), max(0, launch.channels.count - 1))
        engine.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.timeChanged(t)
        }.store(in: &bag)
        engine.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] b in
            self?.buffering = b
        }.store(in: &bag)
        engine.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] p in
            self?.playingChanged(p)
        }.store(in: &bag)
    }

    func activate() {
        start()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    func close() {
        closed = true
        generation += 1
        tuneTask?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        engine.stop()
    }

    func retry() {
        retries = 0
        start()
    }

    func zap(_ delta: Int) {
        tune(to: index + delta, direction: delta)
    }

    func tune(to target: Int, direction: Int = 0) {
        let n = channels.count
        guard n > 0 else { return }
        let i = ((target % n) + n) % n
        if channels[i].adult && !LiveAdultGate.confirmed {
            adultPrompt = AdultPrompt(index: i, direction: direction)
            return
        }
        commitTune(i)
    }

    func confirmAdult() {
        guard let prompt = adultPrompt else { return }
        adultPrompt = nil
        LiveAdultGate.confirmed = true
        commitTune(prompt.index)
    }

    /// Si se rechaza el aviso durante el zapping, se saltan los canales +18 en esa dirección.
    func cancelAdult() {
        guard let prompt = adultPrompt else { return }
        adultPrompt = nil
        guard prompt.direction != 0 else { return }
        let n = channels.count
        var i = prompt.index
        var steps = 0
        while channels[i].adult && steps < n {
            i = ((i + prompt.direction) % n + n) % n
            steps += 1
        }
        if !channels[i].adult { commitTune(i) }
    }

    private func commitTune(_ i: Int) {
        if i == index && error == nil && !loading { return }
        Haptics.select()
        generation += 1
        index = i
        retries = 0
        stream = nil
        error = nil
        loading = true
        openedAt = nil
        engine.stop()
        tuneTask?.cancel()
        // Zapping rápido: el vídeo se abre cuando se deja de cambiar de canal.
        tuneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func start() {
        guard !closed, !channels.isEmpty else { return }
        generation += 1
        let gen = generation
        let current = channel
        loading = true
        error = nil
        openedAt = nil
        lastTime = 0
        lastProgress = .distantPast
        Task { [weak self] in
            do {
                let s: LiveStream = try await APIClient.shared.send(.get, "/channels/\(current.id)/play", timeout: 40)
                guard let self, gen == self.generation, !self.closed else { return }
                guard !s.url.isEmpty, let url = URL(string: s.url) else {
                    throw APIError(status: 404, code: "not_found", message: "Canal no disponible.")
                }
                self.stream = s
                self.openedAt = Date()
                self.engine.open(url: url, startAt: 0)
            } catch is CancellationError {
            } catch {
                guard let self, gen == self.generation, !self.closed else { return }
                self.loading = false
                self.error = APIError.from(error).message
            }
        }
    }

    private func timeChanged(_ t: Double) {
        guard openedAt != nil else { return }
        if t > lastTime + 0.05 { markProgress() }
        lastTime = t
    }

    private func playingChanged(_ p: Bool) {
        playing = p
        if p, openedAt != nil { markProgress() }
    }

    /// VLC informa errores sueltos (segmentos HLS, pistas secundarias) aunque el vídeo siga en marcha:
    /// solo cuenta como fallo si la imagen deja de avanzar.
    private func markProgress() {
        lastProgress = Date()
        if loading || error != nil {
            loading = false
            error = nil
        }
    }

    private func checkHealth() {
        guard !closed, error == nil, let openedAt else { return }
        if engine.isPlaying { lastProgress = Date() }
        let now = Date()
        let progressed = lastProgress != .distantPast
        let stalled = progressed ? now.timeIntervalSince(lastProgress) > 10 : now.timeIntervalSince(openedAt) > 25
        let failed = engine.failedMessage != nil && now.timeIntervalSince(max(lastProgress, openedAt)) > 6
        guard stalled || failed else { return }
        if retries < 2 {
            retries += 1
            start()
        } else {
            engine.stop()
            loading = false
            error = "No se pudo reproducir este canal. Puede estar fuera del aire en este momento."
        }
    }
}

struct LivePlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LivePlayerModel
    @State private var osd = true
    @State private var panel = false
    @State private var hideTask: Task<Void, Never>?

    private static let panelWidth: CGFloat = 340

    init(launch: LiveLaunch) {
        _model = StateObject(wrappedValue: LivePlayerModel(launch: launch))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCPlayerView(engine: model.engine)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { panel ? closePanel() : toggleOsd() }
                .gesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        let dx = value.translation.width
                        guard !panel, abs(dx) > 60, abs(dx) > abs(value.translation.height) else { return }
                        zap(dx < 0 ? 1 : -1)
                    }
                )

            if model.showSpinner {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.6)
                    .allowsHitTesting(false)
            }

            if let error = model.error {
                errorView(error)
            }

            if osd || panel {
                bottomBar.transition(.opacity)
            }

            if osd && !panel && model.channels.count > 1 {
                sideArrows.transition(.opacity)
            }

            if osd || model.error != nil {
                topBar.transition(.opacity)
            }

            if panel {
                channelPanel.transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: osd)
        .animation(Theme.softMotion, value: panel)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            OrientationController.setLandscape(true)
            UIApplication.shared.isIdleTimerDisabled = true
            model.activate()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.close()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationController.setLandscape(false)
        }
        .onChange(of: model.index) { _ in showOsd() }
        .alert(LiveAdultGate.title, isPresented: Binding(get: { model.adultPrompt != nil }, set: { if !$0 { model.cancelAdult() } })) {
            Button("Cancelar", role: .cancel) { model.cancelAdult() }
            Button("Soy mayor de 18") { model.confirmAdult() }
        } message: {
            Text(LiveAdultGate.message)
        }
    }

    // MARK: Capas

    private var topBar: some View {
        HStack {
            CircleIconButton(systemName: "xmark", label: "Cerrar") { dismiss() }
            Spacer()
            CircleIconButton(systemName: "list.number", label: "Lista de canales") { openPanel() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, panel ? Self.panelWidth : 0)
    }

    private var sideArrows: some View {
        HStack {
            CircleIconButton(systemName: "chevron.left", size: 50, label: "Canal anterior") { zap(-1) }
            Spacer()
            CircleIconButton(systemName: "chevron.right", size: 50, label: "Canal siguiente") { zap(1) }
        }
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        let c = model.channel
        let now = model.stream?.epgNow ?? c.epgNow
        return HStack(spacing: 16) {
            ChannelNumberTag(number: c.number, width: 76, fontSize: 24)
            ChannelLogo(url: c.logo, width: 96, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    LiveBadge(text: "EN VIVO")
                    if c.adult { LiveBadge(text: "+18", dark: true) }
                    Text(c.category)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(c.name)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let now {
                    Text("Ahora: \(now)")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if let next = c.epgNext {
                    Text("Después: \(next)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !panel {
                Text("Desliza ◀ ▶ para\ncambiar de canal")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .padding(.trailing, panel ? Self.panelWidth : 0)
        .background {
            LinearGradient(colors: [.clear, Color.black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 38))
                .foregroundColor(.white.opacity(0.7))
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Button("Reintentar") { model.retry() }
                .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 460)
    }

    private var channelPanel: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closePanel() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "play.tv.fill").foregroundColor(Theme.accent2)
                    Text("Canales · \(model.channels.count)")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Theme.text)
                    Spacer()
                    Button { closePanel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.text2)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel(Text("Cerrar lista"))
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 10)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.channels.indices, id: \.self) { i in
                                Button {
                                    closePanel()
                                    model.tune(to: i)
                                } label: {
                                    LivePanelRow(channel: model.channels[i], current: i == model.index)
                                }
                                .buttonStyle(PressableStyle())
                                .id(i)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 20)
                    }
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo(model.index, anchor: .center) }
                    }
                }
            }
            .frame(width: Self.panelWidth)
            .background(Theme.bg.opacity(0.95).ignoresSafeArea())
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).ignoresSafeArea()
            }
        }
    }

    // MARK: Acciones

    private func zap(_ delta: Int) {
        model.zap(delta)
        showOsd()
    }

    private func openPanel() {
        hideTask?.cancel()
        osd = true
        panel = true
    }

    private func closePanel() {
        panel = false
        showOsd()
    }

    private func toggleOsd() {
        if osd {
            hideTask?.cancel()
            osd = false
        } else {
            showOsd()
        }
    }

    private func showOsd() {
        osd = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !panel, model.error == nil else { return }
            osd = false
        }
    }
}

struct LivePanelRow: View {
    let channel: LiveChannel
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(String(channel.number))
                .font(.system(size: 16, weight: .black).monospacedDigit())
                .foregroundColor(current ? Theme.accent2 : Theme.text2)
                .frame(width: 44, alignment: .leading)
            ChannelLogo(url: channel.logo, width: 54, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(channel.category)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if channel.adult { LiveBadge(text: "+18", dark: true) }
            if current {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.accent2)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(current ? Theme.accent.opacity(0.22) : Theme.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(current ? Theme.accent2.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
