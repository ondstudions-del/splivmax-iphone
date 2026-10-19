import SwiftUI
import AVKit
import MediaPlayer

/// Reproductor propio de SPLIVMAX: horizontal a pantalla completa, controles con la identidad de la web.
struct PlayerView: View {
    let request: PlayRequest

    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PlayerController
    @StateObject private var volume = VolumeController()

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var gravity: AVLayerVideoGravity = .resizeAspect
    @State private var seekFlash: SeekFlash?
    @State private var dragKind: DragKind?
    @State private var dragStart: CGFloat = 0
    @State private var hud: HUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var originalBrightness: CGFloat?
    @State private var reporting = false
    @AppStorage(Prefs.subtitleSizeKey) private var subtitleSize = 1
    @AppStorage(Prefs.speedMeterKey) private var speedMeterPinned = false
    @AppStorage(Prefs.preloadKey) private var preloadOnWiFi = true

    init(request: PlayRequest) {
        self.request = request
        _controller = StateObject(wrappedValue: PlayerController(request: request))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if controller.usesVLC {
                    VLCPlayerView(engine: controller.vlc)
                        .ignoresSafeArea()
                } else {
                    PlayerLayerView(player: controller.player, gravity: gravity) { layer in
                        controller.attach(layer: layer)
                    }
                    .ignoresSafeArea()
                }

                VolumeHost(controller: volume)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)

                gestureLayer(size: geo.size)

                captionView

                if showLoadingScreen {
                    PlayerLoadingView(title: controller.data?.title.title ?? request.title,
                                      subtitle: controller.data?.episode?.label,
                                      backdrop: controller.data?.title.backdrop,
                                      status: loadingStatus,
                                      offline: controller.waitingForNetwork,
                                      bitsPerSecond: controller.throughput)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if controller.isBuffering && !isFailed && controller.phase != .ended {
                    VStack(spacing: 18) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.6)
                        if controller.waitingForNetwork {
                            Label("Sin conexión. El vídeo seguirá solo cuando vuelva la red.", systemImage: "wifi.slash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.55), in: Capsule())
                        } else if let bps = controller.throughput {
                            SpeedBadge(bitsPerSecond: bps, height: nil)
                        }
                    }
                    .allowsHitTesting(false)
                }

                if controlsVisible && !isFailed && controller.phase != .ended {
                    controls
                        .transition(.opacity)
                } else if speedMeterPinned, !isFailed, let bps = controller.throughput {
                    SpeedBadge(bitsPerSecond: bps, height: controller.videoHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let flash = seekFlash {
                    SeekFlashView(flash: flash)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: flash.forward ? .trailing : .leading)
                        .padding(.horizontal, geo.size.width * 0.12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let hud {
                    HUDView(hud: hud)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hud.kind == .brightness ? .leading : .trailing)
                        .padding(.horizontal, 40)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let seconds = controller.nextCountdown, let next = controller.data?.next, !isFailed {
                    NextEpisodeCard(next: next, seconds: seconds, onPlay: { controller.playNext() }, onCancel: { controller.cancelCountdown() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 24)
                        .padding(.bottom, controlsVisible ? 96 : 28)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if case .failed(let message, let code) = controller.phase {
                    failureView(message: message, code: code)
                }

                if controller.phase == .ended {
                    endedView
                }
            }
            .animation(.easeOut(duration: 0.35), value: showLoadingScreen)
            .animation(.easeOut(duration: 0.25), value: controlsVisible)
            .animation(.easeOut(duration: 0.2), value: seekFlash)
            .animation(.easeOut(duration: 0.2), value: hud)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controller.nextCountdown != nil)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            OrientationController.setLandscape(true)
            originalBrightness = ScreenBrightness.value
            scheduleHide()
        }
        .task { await controller.start() }
        .onDisappear {
            hideTask?.cancel()
            controller.close()
            if let originalBrightness { ScreenBrightness.value = originalBrightness }
            OrientationController.setLandscape(false)
            coordinator.didClose()
            Task { await session.refreshMe() }
        }
        .onChange(of: preloadOnWiFi) { _ in controller.refreshBuffer() }
        .onChange(of: controller.isPlaying) { playing in
            if playing {
                scheduleHide()
            } else {
                withAnimation { controlsVisible = true }
            }
        }
        .sheet(isPresented: $reporting) {
            ReportSheet(titleId: controller.request.titleId, episodeId: controller.data?.episode?.id, source: "player")
                .environmentObject(session)
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    /// Pantalla «Cargando» desde que se entra al reproductor hasta que se ve el primer fotograma.
    private var showLoadingScreen: Bool {
        !controller.hasVideo && !isFailed && controller.phase != .ended
    }

    private var loadingStatus: String {
        if controller.waitingForNetwork { return "Sin conexión" }
        return controller.data == nil ? "Conectando…" : "Cargando…"
    }

    // MARK: Gestos

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in doubleTap(at: value.location, width: size.width) }
                    .exclusively(before: TapGesture().onEnded { toggleControls() })
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in dragChanged(value, size: size) }
                    .onEnded { _ in dragKind = nil; hideHUDSoon() }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Vídeo"))
            .accessibilityHint(Text("Toca para mostrar u ocultar los controles"))
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func doubleTap(at point: CGPoint, width: CGFloat) {
        guard controller.phase == .playing else { return }
        if point.x < width * 0.4 {
            controller.skip(-10)
            flash(forward: false)
        } else if point.x > width * 0.6 {
            controller.skip(10)
            flash(forward: true)
        } else {
            controller.togglePlay()
        }
        Haptics.tap()
    }

    private func flash(forward: Bool) {
        let count = (seekFlash?.forward == forward ? (seekFlash?.count ?? 0) : 0) + 1
        let f = SeekFlash(forward: forward, count: count)
        seekFlash = f
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if seekFlash == f { seekFlash = nil }
        }
    }

    /// Deslizar en vertical: brillo a la izquierda, volumen a la derecha.
    private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
        if dragKind == nil {
            guard abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
            dragKind = value.startLocation.x < size.width / 2 ? .brightness : .volume
            dragStart = dragKind == .brightness ? ScreenBrightness.value : CGFloat(volume.current)
        }
        guard let kind = dragKind else { return }
        let delta = -value.translation.height / max(200, size.height * 0.8)
        let newValue = min(1, max(0, dragStart + delta))
        if kind == .brightness {
            ScreenBrightness.value = newValue
        } else {
            volume.set(Float(newValue))
        }
        hudTask?.cancel()
        hud = HUD(kind: kind, value: Double(newValue))
    }

    private func hideHUDSoon() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            guard !Task.isCancelled else { return }
            if controller.isPlaying && scrubbing == nil {
                withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
            }
        }
    }

    // MARK: Controles

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 150)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if controller.hasVideo {
                    centerControls
                    Spacer()
                    bottomBar
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(Text("Cerrar reproductor"))

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.data?.title.title ?? request.title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                if let ep = controller.data?.episode {
                    Text(ep.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }

            Spacer()

            if controller.lowData || controller.qualityMode == .saver {
                Label(saverLabel, systemImage: "leaf.fill")
                    .font(.system(size: 11.5, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.ok.opacity(0.25), in: Capsule())
                    .foregroundColor(Theme.ok)
                    .accessibilityLabel(Text("Ahorro de datos activo"))
            }

            if let bps = controller.throughput {
                SpeedBadge(bitsPerSecond: bps, height: controller.videoHeight)
            }

            RoutePickerButton()
                .frame(width: 36, height: 36)
                .accessibilityLabel(Text("AirPlay"))

            if controller.usesVLC {
                Text("MKV")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent2.opacity(0.35), in: Capsule())
                    .accessibilityLabel(Text("Reproductor MKV (VLC)"))
            } else if controller.isPiPPossible {
                Button { controller.togglePiP() } label: {
                    Image(systemName: controller.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("Imagen dentro de imagen"))
            }

            settingsMenu
        }
        .foregroundColor(.white)
    }

    private var saverLabel: String {
        controller.sessionBytes > 0 ? DataUsage.format(Double(controller.sessionBytes)) : "Ahorro"
    }

    private var centerControls: some View {
        HStack(spacing: 64) {
            Button { controller.skip(-10); flash(forward: false); scheduleHide() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .semibold))
            }
            .accessibilityLabel(Text("Retroceder 10 segundos"))

            Button { controller.togglePlay(); scheduleHide() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 74, height: 74)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .opacity(controller.isBuffering ? 0 : 1)
            .accessibilityLabel(Text(controller.isPlaying ? "Pausar" : "Reproducir"))

            Button { controller.skip(10); flash(forward: true); scheduleHide() } label: {
                Image(systemName: "goforward.10").font(.system(size: 30, weight: .semibold))
            }
            .accessibilityLabel(Text("Adelantar 10 segundos"))
        }
        .foregroundColor(.white)
        .buttonStyle(PressableStyle())
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(Format.clock(scrubbing ?? controller.currentTime))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52, alignment: .leading)
                ScrubBar(value: scrubbing ?? controller.currentTime,
                         buffered: controller.bufferedTime,
                         duration: controller.duration,
                         onChanged: { value in
                             scrubbing = value
                             hideTask?.cancel()
                         },
                         onEnded: { value in
                             controller.seek(to: value)
                             scrubbing = nil
                             scheduleHide()
                         })
                Text("-" + Format.clock(max(0, controller.duration - (scrubbing ?? controller.currentTime))))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 58, alignment: .trailing)
            }
            HStack(spacing: 18) {
                Button {
                    gravity = gravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
                    scheduleHide()
                } label: {
                    Label(gravity == .resizeAspect ? "Rellenar" : "Ajustar",
                          systemImage: gravity == .resizeAspect ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                Spacer()
                if controller.data?.next != nil {
                    Button { controller.playNext() } label: {
                        Label("Siguiente episodio", systemImage: "forward.end.fill")
                    }
                }
            }
            .font(.system(size: 13.5, weight: .semibold))
        }
        .foregroundColor(.white)
    }

    private var subtitleBinding: Binding<String> {
        Binding(get: {
            switch controller.subtitleChoice {
            case .off: return "off"
            case .external(let id): return "x:" + id
            case .embedded(let id): return "e:" + id
            }
        }, set: { value in
            if value == "off" {
                controller.subtitlesOff()
            } else if value.hasPrefix("x:"), let sub = controller.data?.subtitles.first(where: { "x:" + $0.id == value }) {
                controller.selectExternal(sub)
            } else if value.hasPrefix("e:"), let opt = controller.embeddedSubtitles.first(where: { "e:" + $0.id == value }) {
                controller.selectEmbedded(opt)
            }
        })
    }

    private var qualityBinding: Binding<String> {
        Binding(get: {
            switch controller.qualityMode {
            case .auto: return "auto"
            case .saver: return "saver"
            case .source(let url): return url
            }
        }, set: { value in
            switch value {
            case "auto": controller.setQuality(.auto)
            case "saver": controller.setQuality(.saver)
            default: controller.setQuality(.source(value))
            }
        })
    }

    private var settingsMenu: some View {
        Menu {
            Picker(selection: subtitleBinding) {
                Text("Desactivados").tag("off")
                ForEach(controller.data?.subtitles ?? []) { sub in
                    Text(sub.label).tag("x:" + sub.id)
                }
                ForEach(controller.embeddedSubtitles) { opt in
                    Text(opt.name).tag("e:" + opt.id)
                }
            } label: {
                Label("Subtítulos", systemImage: "captions.bubble")
            }
            .pickerStyle(.menu)

            if !controller.audioTracks.isEmpty {
                Picker(selection: Binding(get: { controller.selectedAudio ?? "" }, set: { id in
                    if let opt = controller.audioTracks.first(where: { $0.id == id }) { controller.selectAudio(opt) }
                })) {
                    ForEach(controller.audioTracks) { Text($0.name).tag($0.id) }
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                .pickerStyle(.menu)
            }

            Picker(selection: qualityBinding) {
                if controller.hasHLS {
                    Text("Automática").tag("auto")
                    Text("Ahorro de datos").tag("saver")
                }
                ForEach(controller.qualityOptions, id: \.url) { source in
                    Text(source.label).tag(source.url.absoluteString)
                }
            } label: {
                Label("Calidad", systemImage: "dial.medium")
            }
            .pickerStyle(.menu)

            Picker(selection: Binding(get: { controller.rate }, set: { controller.setRate($0) })) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                    Text(r == 1 ? "Normal" : String(format: "%gx", r)).tag(r)
                }
            } label: {
                Label("Velocidad", systemImage: "speedometer")
            }
            .pickerStyle(.menu)

            Picker(selection: $subtitleSize) {
                Text("Pequeños").tag(0)
                Text("Normales").tag(1)
                Text("Grandes").tag(2)
            } label: {
                Label("Tamaño de subtítulos", systemImage: "textformat.size")
            }
            .pickerStyle(.menu)

            Toggle(isOn: $speedMeterPinned) {
                Label("Medidor siempre visible", systemImage: "gauge.with.dots.needle.33percent")
            }

            Toggle(isOn: $preloadOnWiFi) {
                Label("Precarga en Wi-Fi", systemImage: "square.and.arrow.down.on.square")
            }

            Divider()

            Button { reporting = true } label: {
                Label("Reportar un problema", systemImage: "flag")
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .accessibilityLabel(Text("Ajustes de reproducción"))
    }

    // MARK: Subtítulos

    private var captionFontSize: CGFloat {
        let sizes: [CGFloat] = [15, 19, 24]
        return sizes[min(2, max(0, subtitleSize))]
    }

    private var captionView: some View {
        VStack {
            Spacer()
            if let caption = controller.caption {
                Text(caption)
                    .font(.system(size: captionFontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 60)
                    .padding(.bottom, controlsVisible ? 100 : 26)
                    .animation(.easeOut(duration: 0.2), value: controlsVisible)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Estados

    private func failureView(message: String, code: String) -> some View {
        let blocking = ["premium_required", "trial_ended", "daily_limit", "too_many_streams", "not_found", "no_source"].contains(code)
        return ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: code == "offline" ? "wifi.slash" : (blocking ? "lock.fill" : "exclamationmark.triangle"))
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.gradient)
                Text(message)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if code == "premium_required" || code == "trial_ended" {
                    Text(AppConfig.billingMode == .direct
                         ? "Puedes elegir un plan en Perfil › Planes."
                         : "Consulta el estado de tu plan en Perfil.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text2)
                }
                HStack(spacing: 12) {
                    if !blocking {
                        Button("Reintentar") { controller.retry() }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    }
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(30)
        }
    }

    private var endedView: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(controller.data?.title.title ?? request.title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)
                HStack(spacing: 12) {
                    Button { controller.play() } label: {
                        Label("Volver a ver", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(WhiteButtonStyle(fullWidth: false))
                    if controller.data?.next != nil {
                        Button { controller.playNext() } label: {
                            Label("Siguiente", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
        }
    }
}

// MARK: - Piezas del reproductor

/// Medidor de la velocidad de descarga: rojo por debajo de 1 Mbps, amarillo hasta 2,5 Mbps, verde por encima.
struct SpeedBadge: View {
    let bitsPerSecond: Double
    let height: Int?

    private var color: Color {
        switch Speed.level(bitsPerSecond) {
        case .low: return Theme.bad
        case .medium: return Theme.warn
        case .high: return Theme.ok
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(Speed.text(bitsPerSecond))
                .foregroundColor(color)
            if let height, height > 0 {
                Text("· \(height)p").foregroundColor(.white.opacity(0.8))
            }
        }
        .font(.system(size: 12, weight: .bold))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: Speed.text(bitsPerSecond))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Velocidad de la conexión: \(Speed.text(bitsPerSecond))"))
    }
}

/// Pantalla de carga al entrar al reproductor: fondo del título, indicador animado y estado de la conexión.
private struct PlayerLoadingView: View {
    let title: String
    let subtitle: String?
    let backdrop: URL?
    let status: String
    let offline: Bool
    let bitsPerSecond: Double?

    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black
            if let backdrop {
                RemoteImage(backdrop, maxPixel: 1200)
                    .blur(radius: 16)
                    .opacity(0.4)
            }
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    Image(systemName: offline ? "wifi.slash" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 68, height: 68)

                VStack(spacing: 6) {
                    Text(status)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(.white)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13.5))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    if offline {
                        Text("Empezará solo en cuanto vuelva la conexión.")
                            .font(.system(size: 13.5))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
                .multilineTextAlignment(.center)

                if !offline, let bitsPerSecond {
                    SpeedBadge(bitsPerSecond: bitsPerSecond, height: nil)
                }
            }
            .padding(.horizontal, 40)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct SeekFlash: Equatable {
    let forward: Bool
    let count: Int
    let id = UUID()
}

private struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: flash.forward ? "goforward" : "gobackward")
                .font(.system(size: 26, weight: .bold))
            Text("\(flash.forward ? "+" : "−")\(flash.count * 10) s")
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundColor(.white)
        .frame(width: 110, height: 110)
        .background(.black.opacity(0.4), in: Circle())
    }
}

private enum DragKind { case brightness, volume }

private struct HUD: Equatable {
    let kind: DragKind
    let value: Double
}

private struct HUDView: View {
    let hud: HUD

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hud.kind == .brightness ? "sun.max.fill" : (hud.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 18, weight: .semibold))
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Theme.gradient).frame(height: g.size.height * hud.value)
                }
            }
            .frame(width: 6, height: 120)
        }
        .foregroundColor(.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct ScrubBar: View {
    let value: Double
    let buffered: Double
    let duration: Double
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let progress = duration > 0 ? min(1, max(0, value / duration)) : 0
            let loaded = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let barHeight: CGFloat = dragging ? 6 : 4
            let knob: CGFloat = dragging ? 18 : 13
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: barHeight)
                Capsule().fill(Color.white.opacity(0.38)).frame(width: width * loaded, height: barHeight)
                Capsule().fill(Theme.gradient).frame(width: width * progress, height: barHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: width * progress - knob / 2)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        onChanged(min(1, max(0, g.location.x / width)) * duration)
                    }
                    .onEnded { g in
                        dragging = false
                        onEnded(min(1, max(0, g.location.x / width)) * duration)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel(Text("Posición"))
        .accessibilityValue(Text("\(Format.clock(value)) de \(Format.clock(duration))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onEnded(min(duration, value + 10))
            case .decrement: onEnded(max(0, value - 10))
            @unknown default: break
            }
        }
    }
}

private struct NextEpisodeCard: View {
    let next: PlaybackNext
    let seconds: Int
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(next.thumbnail, maxPixel: 320, placeholderIcon: "play.rectangle")
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGUIENTE EPISODIO")
                    .font(.system(size: 10.5, weight: .heavy))
                    .kerning(1)
                    .foregroundColor(Theme.accent2)
                Text(next.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("Ver ahora (\(seconds))", systemImage: "play.fill")
                    }
                    .buttonStyle(WhiteButtonStyle(fullWidth: false))
                    Button("Cancelar", action: onCancel)
                        .buttonStyle(GlassButtonStyle())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Puentes con UIKit

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onLayer: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        let layer = view.playerLayer
        DispatchQueue.main.async { onLayer(layer) }
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            view.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }
}

struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent2)
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Control de volumen del sistema mediante un MPVolumeView oculto (sin el aviso flotante de iOS).
@MainActor
final class VolumeController: ObservableObject {
    let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()

    var current: Float { AVAudioSession.sharedInstance().outputVolume }

    func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = min(1, max(0, value))
        slider.sendActions(for: .valueChanged)
    }
}

struct VolumeHost: UIViewRepresentable {
    let controller: VolumeController

    func makeUIView(context: Context) -> MPVolumeView { controller.view }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    static var value: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = min(1, max(0, newValue)) }
    }
}
