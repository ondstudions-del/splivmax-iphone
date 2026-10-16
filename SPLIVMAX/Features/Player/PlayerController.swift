import AVFoundation
import AVKit
import MediaPlayer
import Combine
import UIKit

struct PlayRequest: Identifiable, Equatable {
    let id = UUID()
    let titleId: String
    var episodeId: String?
    let title: String
}

/// Abre el reproductor a pantalla completa desde cualquier pantalla.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var request: PlayRequest?
    /// Aumenta al cerrar el reproductor: las fichas recargan el progreso.
    @Published private(set) var closedCount = 0

    func play(titleId: String, episodeId: String? = nil, title: String) {
        request = PlayRequest(titleId: titleId, episodeId: episodeId, title: title)
    }

    func didClose() {
        closedCount += 1
    }
}

struct MediaOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum SubtitleChoice: Equatable {
    case off
    case external(String)
    case embedded(String)
}

enum QualityMode: Equatable {
    case auto
    case saver
    case source(String)
}

/// Lógica del reproductor: fuentes firmadas, adaptación a la red, subtítulos, pistas de audio,
/// progreso con el servidor, siguiente episodio, PiP, AirPlay y controles de la pantalla de bloqueo.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case loading
        case playing
        case failed(message: String, code: String)
        case ended
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedTime: Double = 0
    @Published private(set) var data: PlaybackData?
    @Published private(set) var caption: String?
    @Published private(set) var subtitleChoice: SubtitleChoice = .off
    @Published private(set) var embeddedSubtitles: [MediaOption] = []
    @Published private(set) var audioTracks: [MediaOption] = []
    @Published private(set) var selectedAudio: String?
    @Published private(set) var nextCountdown: Int?
    @Published private(set) var qualityMode: QualityMode = .auto
    @Published private(set) var currentSource: PlaybackSource?
    @Published private(set) var rate: Float = 1
    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPPossible = false
    @Published private(set) var lowData = false
    @Published private(set) var subtitlesLoading = false
    /// Velocidad de descarga medida (bits por segundo) para el medidor.
    @Published private(set) var throughput: Double?
    /// Altura del vídeo que se está viendo (480, 720, 1080…).
    @Published private(set) var videoHeight: Int?
    /// Bytes de vídeo descargados en esta reproducción.
    @Published private(set) var sessionBytes: Int64 = 0
    /// Ya se ve el vídeo: a partir de aquí las esperas muestran solo el indicador pequeño.
    @Published private(set) var hasVideo = false
    /// Sin conexión: el vídeo sigue solo en cuanto vuelva la red.
    @Published private(set) var waitingForNetwork = false

    let player = AVPlayer()
    private(set) var request: PlayRequest
    private let api = APIClient.shared
    private let network = NetworkMonitor.shared

    private var candidates: [PlaybackSource] = []
    private var candidateIndex = 0
    private var pendingSeek: Double?
    private var started = false
    private var countdownCancelled = false
    private var watched: Double = 0
    private var lastTick: Double = 0
    private var stallTimes: [Date] = []
    private var smoothSince: Date?
    private var rampedUp = false
    private var sentPause = false
    private var closed = false
    private var quickStartedAt: Date?
    private var quickStartDisabled = false
    /// Solo una pausa pedida (usuario, auriculares, salir de la app) detiene el vídeo; cargas y cambios de red no.
    private var userPaused = false
    private var waitingSince: Date?
    private var networkChangedAt: Date?
    private var recoveries: [Date] = []
    private var retryStartWhenOnline = false
    private var startAttempts = 0
    private var switchingItem = false
    private var lastDataAt = Date()

    private var meterTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var sampledItem: ObjectIdentifier?
    private var sampledBytes: Int64 = 0
    private var sampledAt = Date()
    private var unsavedBytes: Int64 = 0
    private var lastUsageFlush = Date()

    private var cues: [SubtitleCue] = []
    private var cueCache: [String: [SubtitleCue]] = [:]
    private var legibleGroup: AVMediaSelectionGroup?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleOptions: [String: AVMediaSelectionOption] = [:]
    private var audibleOptions: [String: AVMediaSelectionOption] = [:]

    private var itemObservers: [NSKeyValueObservation] = []
    private var playerObservers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var heartbeat: Task<Void, Never>?
    private var pip: AVPictureInPictureController?
    private var pipObserver: NSKeyValueObservation?
    private var nowPlayingUpdated = Date.distantPast
    private var artwork: MPMediaItemArtwork?

    init(request: PlayRequest) {
        self.request = request
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.isMuted = false
        player.volume = 1
        ImagePipeline.shared.videoActive = true
        observePlayer()
        observeSystem()
        setupRemoteCommands()
        startMeter()
    }

    // MARK: Inicio

    func start() async {
        phase = .loading
        isBuffering = true
        hasVideo = false
        waitingForNetwork = false
        retryStartWhenOnline = false
        userPaused = false
        recoveries = []
        keepScreenAwake(true)
        lowData = network.prefersLowData
        activateAudio()
        var query: [String: String] = [:]
        if let ep = request.episodeId { query["episode"] = ep }
        if lowData { query["lite"] = "1" }
        do {
            let d: PlaybackData = try await api.send(.get, "/playback/\(request.titleId)", query: query)
            guard !closed else { return }
            startAttempts = 0
            data = d
            request.episodeId = d.episode?.id
            countdownCancelled = false
            nextCountdown = nil
            started = false
            candidates = order(d.sources)
            candidateIndex = 0
            guard let first = candidates.first else {
                fail(message: "Este contenido todavía no tiene una fuente de vídeo disponible.", code: "no_source")
                return
            }
            load(first, at: Double(d.resume))
            selectInitialSubtitle(d)
            loadArtwork(d.title.backdrop)
        } catch is CancellationError {
        } catch {
            let e = APIError.from(error)
            let networkIssue = ["offline", "timeout", "network", "unreachable"].contains(e.code)
            if !network.isOnline || (networkIssue && startAttempts < 4) {
                // Sin red al entrar: se queda cargando y arranca solo cuando vuelva la conexión.
                retryStartWhenOnline = true
                waitingForNetwork = !network.isOnline
                if network.isOnline {
                    startAttempts += 1
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, self.retryStartWhenOnline, !self.closed else { return }
                        await self.start()
                    }
                }
                return
            }
            fail(message: e.message, code: e.code)
        }
    }

    func retry() {
        startAttempts = 0
        Task { await start() }
    }

    /// El vídeo arranca con sonido aunque el iPhone esté en modo silencio.
    private func activateAudio() {
        let audio = AVAudioSession.sharedInstance()
        if audio.category != .playback || audio.mode != .moviePlayback {
            try? audio.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        }
        try? audio.setActive(true)
        player.isMuted = false
        player.volume = 1
    }

    /// HLS primero (se adapta solo); en ahorro de datos, el MP4 más ligero antes que el de más calidad.
    private func order(_ sources: [PlaybackSource]) -> [PlaybackSource] {
        let hls = sources.filter(\.hls).sorted { $0.quality > $1.quality }
        var files = sources.filter { !$0.hls }.sorted { $0.quality > $1.quality }
        if lowData || !network.isOnline { files.reverse() }
        return hls + files
    }

    private func load(_ source: PlaybackSource, at time: Double) {
        removeItemObservers()
        let shouldPlay = !userPaused
        // El vídeo puede usar cualquier red disponible (Wi-Fi, datos móviles o modo datos reducidos).
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true,
        ]
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        // Búfer corto para arrancar (y no descargar de más antes de saltar al punto guardado);
        // al empezar a reproducir se amplía según la red.
        item.preferredForwardBufferDuration = 4
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        // Empieza por la primera calidad que cumple los topes en lugar de medir la red antes de arrancar.
        item.startsOnFirstEligibleVariant = true
        currentSource = source
        pendingSeek = time > 5 ? time : nil
        rampedUp = false
        smoothSince = nil
        stallTimes = []
        quickStartedAt = nil
        quickStartDisabled = false
        lastDataAt = Date()
        applyBitrate(to: item, startup: true)
        observe(item)
        if pendingSeek != nil && player.rate != 0 {
            // Se detiene sin que cuente como pausa: el vídeo sigue en cuanto llega al punto donde iba.
            switchingItem = true
            player.pause()
        }
        player.replaceCurrentItem(with: item)
        isBuffering = true
        // Sin punto guardado se pide reproducir ya: AVPlayer empieza en cuanto tiene datos.
        if pendingSeek == nil && shouldPlay {
            player.defaultRate = rate
            player.play()
        }
    }

    /// Vídeo que se precarga en Wi-Fi (5 minutos); AVPlayer puede guardar menos si el iPhone va justo de memoria.
    static let preloadSeconds: Double = 300

    static var preloadEnabled: Bool {
        UserDefaults.standard.object(forKey: Prefs.preloadKey) as? Bool ?? true
    }

    /// Lo que se descarga por adelantado una vez arrancado: poco en ahorro de datos, moderado con
    /// datos móviles y, en Wi-Fi, varios minutos (precarga) para que un bajón de la conexión no corte el vídeo.
    private var steadyBuffer: Double {
        if lowData || qualityMode == .saver { return 10 }
        if network.isWiFi { return Self.preloadEnabled ? Self.preloadSeconds : 0 }
        return 40
    }

    /// Se llama al cambiar la red o la precarga: el búfer se ajusta sin cortar la reproducción.
    func refreshBuffer() {
        guard started, !closed, let item = player.currentItem else { return }
        let target = steadyBuffer
        if item.preferredForwardBufferDuration != target { item.preferredForwardBufferDuration = target }
    }

    /// Tope de datos móviles en calidad automática (≈1080p ligero); en Wi-Fi no hay tope.
    private static let cellularPeakBitRate: Double = 4_000_000

    /// Resolución de la pantalla en horizontal: no tiene sentido descargar más píxeles de los que se ven.
    private var screenPixels: CGSize {
        if player.isExternalPlaybackActive { return .zero }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let size = scenes.first?.screen.nativeBounds.size, size.width > 0 else { return .zero }
        return CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
    }

    /// Arranca con un tope de calidad acorde a la última velocidad medida en esta red (empieza a verse antes)
    /// y lo libera cuando la reproducción va fluida. En ahorro de datos el tope es permanente.
    private func applyBitrate(to item: AVPlayerItem?, startup: Bool) {
        guard let item, currentSource?.hls == true else { return }
        if lowData || qualityMode == .saver {
            item.preferredPeakBitRate = 900_000
            item.preferredPeakBitRateForExpensiveNetworks = 900_000
            item.preferredMaximumResolution = CGSize(width: 854, height: 480)
            return
        }
        item.preferredMaximumResolution = screenPixels
        // Al pasar de Wi-Fi a datos móviles AVPlayer aplica este tope solo, sin cortar el vídeo.
        item.preferredPeakBitRateForExpensiveNetworks = Self.cellularPeakBitRate
        if startup {
            let wifi = network.isWiFi
            let cap: Double = wifi ? 4_000_000 : 2_500_000
            if let estimate = BandwidthMemory.estimate(wifi: wifi) {
                let target: Double = min(estimate * 0.5, cap)
                item.preferredPeakBitRate = max(700_000.0, target)
            } else {
                item.preferredPeakBitRate = wifi ? 2_500_000.0 : 1_200_000.0
            }
        } else if !stallTimes.isEmpty && !rampedUp {
            item.preferredPeakBitRate = 2_500_000
        } else {
            item.preferredPeakBitRate = 0
        }
    }

    private func dataArrived(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        lastDataAt = Date()
        quickStartIfPossible(item)
    }

    /// AVPlayer espera bastante búfer antes de empezar; con 2-3 s ya cargados se arranca
    /// (si esto provoca un corte enseguida, se vuelve al criterio de AVPlayer).
    private func quickStartIfPossible(_ item: AVPlayerItem) {
        guard item === player.currentItem, !quickStartDisabled, !closed,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay == .toMinimizeStalls,
              pendingSeek == nil else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        var ahead: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            if start <= now + 0.5 && end > now {
                ahead = end - now
                break
            }
        }
        let needed: Double = (network.isWiFi && !lowData) ? 2 : 3
        guard ahead >= needed else { return }
        quickStartedAt = Date()
        player.playImmediately(atRate: rate)
    }

    // MARK: Observadores

    private func observe(_ item: AVPlayerItem) {
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(status, item: item) }
        })
        itemObservers.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let keepUp = item.isPlaybackLikelyToKeepUp
            Task { @MainActor in
                guard let self, keepUp, self.player.timeControlStatus != .playing else { return }
                if self.isPlaying && !self.userPaused { self.player.play() }
            }
        })
        itemObservers.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.dataArrived(item) }
        })
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.didEnd() }
            .store(in: &itemBag)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.sourceFailed(err)
            }
            .store(in: &itemBag)
        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stalled() }
            .store(in: &itemBag)
    }

    private func removeItemObservers() {
        itemObservers.forEach { $0.invalidate() }
        itemObservers = []
        itemBag = []
    }

    private func observePlayer() {
        playerObservers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(status) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.interruption(note) }
            .store(in: &bag)
        center.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                // Se desconectaron los auriculares: se pausa como en el resto de iOS.
                self?.pause()
            }
            .store(in: &bag)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isPiPActive, self.player.isExternalPlaybackActive == false else { return }
                self.pause()
            }
            .store(in: &bag)
        network.$prefersLowData
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] low in
                guard let self else { return }
                self.lowData = low
                self.applyBitrate(to: self.player.currentItem, startup: false)
                self.refreshBuffer()
            }
            .store(in: &bag)
        network.$isWiFi
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshBuffer()
                self.networkChanged()
            }
            .store(in: &bag)
        network.$isOnline
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] online in
                guard let self else { return }
                if online { self.networkChanged() } else if self.isBuffering { self.waitingForNetwork = true }
            }
            .store(in: &bag)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Al volver a la app iOS puede haber restablecido el apagado automático de la pantalla.
                guard let self, !self.closed, self.isPlaying || self.isBuffering else { return }
                UIApplication.shared.isIdleTimerDisabled = false
                self.keepScreenAwake(true)
            }
            .store(in: &bag)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            duration = finite(item.duration.seconds)
            if phase != .playing { phase = .playing }
            Task { await loadMediaOptions(for: item) }
            if let seek = pendingSeek, duration == 0 || seek < duration - 20 {
                pendingSeek = nil
                // Con margen hacia atrás AVPlayer retoma en el inicio de segmento más cercano: arranca antes.
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600),
                            toleranceBefore: CMTime(seconds: 3, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor in self?.resumeUnlessPaused() }
                }
            } else {
                pendingSeek = nil
                resumeUnlessPaused()
            }
        case .failed:
            sourceFailed(item.error)
        default:
            break
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        if status != .paused { switchingItem = false }
        switch status {
        case .playing:
            isPlaying = true
            isBuffering = false
            sentPause = false
            if smoothSince == nil { smoothSince = Date() }
            waitingSince = nil
            if waitingForNetwork { waitingForNetwork = false }
            if !hasVideo { hasVideo = true }
            keepScreenAwake(true)
            if !started {
                started = true
                report("start")
                startHeartbeat()
            }
            refreshBuffer()
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
            smoothSince = nil
            if waitingSince == nil { waitingSince = Date() }
            keepScreenAwake(true)
        case .paused:
            if switchingItem {
                isBuffering = true
                return
            }
            isPlaying = false
            isBuffering = false
            smoothSince = nil
            waitingSince = nil
            keepScreenAwake(false)
            if started && !sentPause && phase == .playing {
                sentPause = true
                report("pause")
            }
        @unknown default:
            break
        }
        updateNowPlaying(force: true)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !closed else { return }
        if isPlaying, seconds > lastTick, seconds - lastTick < 1.5 {
            watched += seconds - lastTick
        }
        lastTick = seconds
        currentTime = seconds
        if let item = player.currentItem {
            let d = finite(item.duration.seconds)
            if d > 0, abs(d - duration) > 0.5 { duration = d }
            if let range = item.loadedTimeRanges.last?.timeRangeValue {
                bufferedTime = finite((range.start + range.duration).seconds)
            }
        }
        if case .external = subtitleChoice {
            let text = SubtitleParser.caption(in: cues, at: seconds)
            if text != caption { caption = text }
        }
        // Tras 8 s sin cortes se libera el tope de calidad inicial.
        if !rampedUp, let since = smoothSince, Date().timeIntervalSince(since) > 8 {
            rampedUp = true
            applyBitrate(to: player.currentItem, startup: false)
        }
        updateCountdown(seconds)
        updateNowPlaying(force: false)
    }

    // MARK: Controles

    func play() {
        guard phase != .loading || player.currentItem?.status == .readyToPlay else { return }
        userPaused = false
        if phase == .ended {
            seek(to: 0)
            phase = .playing
        }
        activateAudio()
        player.defaultRate = rate
        player.play()
    }

    func pause() {
        userPaused = true
        if switchingItem {
            switchingItem = false
            isPlaying = false
            isBuffering = false
        }
        player.pause()
    }

    private func resumeUnlessPaused() {
        guard !userPaused, !closed else { return }
        play()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double, precise: Bool = true) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        let tolerance = CMTime(seconds: precise ? 0.3 : 1, preferredTimescale: 600)
        currentTime = target
        if target < duration - Double(data?.settings.countdown ?? 10) - 1 { nextCountdown = nil }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta, precise: false)
    }

    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if isPlaying { player.rate = value }
    }

    func setQuality(_ mode: QualityMode) {
        guard mode != qualityMode else { return }
        qualityMode = mode
        switch mode {
        case .auto, .saver:
            if currentSource?.hls == true {
                rampedUp = mode == .auto
                applyBitrate(to: player.currentItem, startup: false)
                refreshBuffer()
            } else if let hls = candidates.first(where: \.hls) {
                switchTo(hls)
            }
        case .source(let url):
            if let source = candidates.first(where: { $0.url.absoluteString == url }) { switchTo(source) }
        }
    }

    private func switchTo(_ source: PlaybackSource) {
        guard source != currentSource else { return }
        let position = currentTime
        candidateIndex = candidates.firstIndex(of: source) ?? candidateIndex
        load(source, at: position)
    }

    var qualityOptions: [PlaybackSource] {
        candidates.filter { !$0.hls }
    }

    var hasHLS: Bool { candidates.contains(where: \.hls) }

    // MARK: Subtítulos y audio

    private func selectInitialSubtitle(_ d: PlaybackData) {
        let pref = (d.preferredSubtitle ?? "off").lowercased()
        guard pref != "off", !pref.isEmpty else {
            subtitleChoice = .off
            caption = nil
            return
        }
        if let match = d.subtitles.first(where: { $0.lang.lowercased() == pref }) {
            selectExternal(match)
        }
    }

    func selectExternal(_ sub: PlaybackSubtitle) {
        subtitleChoice = .external(sub.id)
        caption = nil
        if let group = legibleGroup, let item = player.currentItem { item.select(nil, in: group) }
        if let cached = cueCache[sub.id] {
            cues = cached
            return
        }
        cues = []
        subtitlesLoading = true
        Task {
            let loaded = (try? await SubtitleParser.load(sub.url)) ?? []
            subtitlesLoading = false
            cueCache[sub.id] = loaded
            if subtitleChoice == .external(sub.id) { cues = loaded }
        }
    }

    func selectEmbedded(_ option: MediaOption) {
        guard let group = legibleGroup, let opt = legibleOptions[option.id], let item = player.currentItem else { return }
        item.select(opt, in: group)
        subtitleChoice = .embedded(option.id)
        caption = nil
        cues = []
    }

    func subtitlesOff() {
        subtitleChoice = .off
        caption = nil
        cues = []
        if let group = legibleGroup, let item = player.currentItem, group.allowsEmptySelection { item.select(nil, in: group) }
    }

    func selectAudio(_ option: MediaOption) {
        guard let group = audibleGroup, let opt = audibleOptions[option.id], let item = player.currentItem else { return }
        item.select(opt, in: group)
        selectedAudio = option.id
    }

    private func loadMediaOptions(for item: AVPlayerItem) async {
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            legibleGroup = group
            let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            var map: [String: AVMediaSelectionOption] = [:]
            var list: [MediaOption] = []
            for (i, opt) in options.enumerated() {
                let id = "s\(i)"
                map[id] = opt
                list.append(MediaOption(id: id, name: opt.displayName))
            }
            legibleOptions = map
            embeddedSubtitles = list
            if case .external = subtitleChoice {
                item.select(nil, in: group)
            } else if subtitleChoice == .off {
                let pref = (data?.preferredSubtitle ?? "off").lowercased()
                if pref != "off", let match = options.firstIndex(where: { ($0.extendedLanguageTag ?? $0.locale?.identifier ?? "").lowercased().hasPrefix(pref) }) {
                    selectEmbedded(list[match])
                } else if group.allowsEmptySelection {
                    item.select(nil, in: group)
                }
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audibleGroup = group
            var map: [String: AVMediaSelectionOption] = [:]
            var list: [MediaOption] = []
            for (i, opt) in group.options.enumerated() {
                let id = "a\(i)"
                map[id] = opt
                list.append(MediaOption(id: id, name: opt.displayName))
            }
            audibleOptions = map
            audioTracks = list.count > 1 ? list : []
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedAudio = map.first { $0.value == selected }?.key
            }
        }
    }

    // MARK: Fin, siguiente episodio y errores

    private func updateCountdown(_ seconds: Double) {
        guard let d = data, d.next != nil, d.settings.autoplayNext, !countdownCancelled, duration > 60 else {
            if nextCountdown != nil { nextCountdown = nil }
            return
        }
        let left = duration - seconds
        let window = Double(max(5, d.settings.countdown))
        if left <= window && left > 0 {
            let value = Int(left.rounded(.up))
            if nextCountdown != value { nextCountdown = value }
        } else if nextCountdown != nil {
            nextCountdown = nil
        }
    }

    func cancelCountdown() {
        countdownCancelled = true
        nextCountdown = nil
    }

    private func didEnd() {
        report("ended")
        stopHeartbeat()
        started = false
        if let d = data, d.next != nil, d.settings.autoplayNext, !countdownCancelled {
            playNext()
        } else {
            phase = .ended
            allowScreenSleep()
        }
    }

    func playNext() {
        guard let next = data?.next else { return }
        if started {
            report("stop")
            stopHeartbeat()
            started = false
        }
        request.episodeId = next.id
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        resetTrackState()
        Task { await start() }
    }

    private func resetTrackState() {
        currentTime = 0
        duration = 0
        bufferedTime = 0
        caption = nil
        cues = []
        cueCache = [:]
        legibleGroup = nil
        audibleGroup = nil
        legibleOptions = [:]
        audibleOptions = [:]
        embeddedSubtitles = []
        audioTracks = []
        selectedAudio = nil
        subtitleChoice = .off
        nextCountdown = nil
        lastTick = 0
        watched = 0
    }

    private func sourceFailed(_ error: Error?) {
        guard !closed, let d = data else { return }
        if isNetworkError(error) && canRecover {
            // Fallo de red: no se muestra error, se sigue en el mismo punto en cuanto haya conexión.
            switchingItem = true
            isBuffering = true
            if network.isOnline {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.recover()
                }
            } else {
                waitingForNetwork = true
            }
            return
        }
        let message = (error as NSError?)?.localizedDescription ?? "error"
        Task {
            let _: [String: Bool]? = try? await api.send(.post, "/playback/error", body: [
                "title_id": d.title.id,
                "code": "ios_\((error as NSError?)?.code ?? 0)",
                "message": String(message.prefix(280)),
                "stream_id": d.streamId,
            ])
        }
        // Si una fuente falla se prueba la siguiente desde el mismo punto.
        let position = max(currentTime, pendingSeek ?? 0)
        if candidateIndex + 1 < candidates.count {
            candidateIndex += 1
            load(candidates[candidateIndex], at: position)
        } else {
            fail(message: network.isOnline
                 ? "No pudimos reproducir este contenido. Inténtalo de nuevo en unos minutos."
                 : "Se perdió la conexión. Revisa tu red e inténtalo de nuevo.",
                 code: network.isOnline ? "playback_failed" : "offline")
        }
    }

    /// Cortes repetidos: en HLS se baja el tope de calidad; con MP4 se pasa a una versión más ligera.
    private func stalled() {
        let now = Date()
        stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 90 } + [now]
        rampedUp = false
        smoothSince = nil
        if let quick = quickStartedAt, now.timeIntervalSince(quick) < 8 { quickStartDisabled = true }
        guard stallTimes.count >= 2, qualityMode == .auto, !lowData else { return }
        if currentSource?.hls == true {
            var measured: Double = 1_200_000
            if let throughput { measured = max(600_000.0, throughput * 0.6) }
            let ceiling: Double = stallTimes.count >= 3 ? 1_200_000 : 2_500_000
            player.currentItem?.preferredPeakBitRate = min(ceiling, measured)
        } else if let current = currentSource,
                  let lighter = candidates.filter({ !$0.hls && $0.quality < current.quality }).max(by: { $0.quality < $1.quality }) {
            stallTimes = []
            switchTo(lighter)
        }
    }

    private func fail(message: String, code: String) {
        switchingItem = false
        waitingForNetwork = false
        phase = .failed(message: message, code: code)
        isBuffering = false
        allowScreenSleep()
    }

    // MARK: Red: el vídeo no se detiene por cargas ni cambios de conexión

    private static let networkErrorCodes: Set<Int> = [
        NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive, NSURLErrorDataNotAllowed,
    ]

    private func isNetworkError(_ error: Error?) -> Bool {
        if !network.isOnline { return true }
        var current = error as NSError?
        var depth = 0
        while let e = current, depth < 5 {
            if e.domain == NSURLErrorDomain && Self.networkErrorCodes.contains(e.code) { return true }
            // CoreMedia: un segmento no llegó a tiempo.
            if e.domain == "CoreMediaErrorDomain" && e.code == -12889 { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private var canRecover: Bool {
        let now = Date()
        return recoveries.filter { now.timeIntervalSince($0) < 120 }.count < 5
    }

    /// Reabre la fuente actual en el punto donde iba (conexión nueva por la red disponible).
    private func recover() {
        guard !closed, phase != .ended, isBuffering, !userPaused, player.currentItem != nil,
              let source = currentSource else { return }
        if case .failed = phase { return }
        let now = Date()
        if let last = recoveries.last, now.timeIntervalSince(last) < 3 { return }
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 120 } + [now]
        waitingForNetwork = false
        waitingSince = nil
        load(source, at: max(currentTime, pendingSeek ?? 0))
    }

    /// Cambio de red (Wi-Fi ↔ datos móviles o vuelve la conexión).
    private func networkChanged() {
        guard !closed, network.isOnline else { return }
        networkChangedAt = Date()
        if retryStartWhenOnline {
            retryStartWhenOnline = false
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !self.closed else { return }
                await self.start()
            }
        } else if waitingForNetwork {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.recover()
            }
        }
    }

    /// Si el vídeo espera datos y no llega nada con la red disponible (conexión colgada tras cambiar de red),
    /// se reabre la conexión en el mismo punto sin que el usuario tenga que hacer nada.
    private func watchdog() {
        guard !closed, isBuffering, !userPaused, network.isOnline, canRecover,
              currentSource != nil, player.currentItem != nil else { return }
        if case .failed = phase { return }
        let waiting = waitingSince != nil || switchingItem || player.currentItem?.status == .unknown
        guard waiting else { return }
        let now = Date()
        let recentChange = networkChangedAt.map { now.timeIntervalSince($0) < 30 } ?? false
        let limit: Double = recentChange ? 5 : (started ? 12 : 20)
        if now.timeIntervalSince(lastDataAt) > limit { recover() }
    }

    // MARK: Pantalla encendida

    /// La pantalla no se apaga mientras se reproduce o carga una película o un episodio.
    /// En pausa se mantiene encendida unos minutos más y después iOS puede apagarla.
    private func keepScreenAwake(_ awake: Bool) {
        idleTask?.cancel()
        idleTask = nil
        guard !closed else { return }
        if awake {
            UIApplication.shared.isIdleTimerDisabled = true
            return
        }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled, let controller = self, !controller.isPlaying, !controller.isBuffering else { return }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func allowScreenSleep() {
        idleTask?.cancel()
        idleTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Progreso con el servidor

    private func startHeartbeat() {
        heartbeat?.cancel()
        let interval = UInt64(max(5, data?.settings.interval ?? 15))
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isPlaying { self.report("progress") }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func report(_ event: String) {
        guard let d = data else { return }
        let body: [String: Any] = [
            "title_id": d.title.id,
            "episode_id": d.episode?.id ?? "",
            "stream_id": d.streamId,
            "position": (currentTime * 10).rounded() / 10,
            "duration": (duration * 10).rounded() / 10,
            "watched": (watched * 10).rounded() / 10,
            "event": event,
        ]
        watched = 0
        Task { [weak self] in
            do {
                let _: HeartbeatResponse = try await APIClient.shared.send(.post, "/playback/progress", body: body)
            } catch let e as APIError where e.code == "stream_expired" && event != "stop" && event != "ended" {
                await self?.renewStream()
            } catch {}
        }
    }

    /// La sesión de reproducción caducó (pausa larga): se pide una nueva sin cortar el vídeo.
    private func renewStream() async {
        guard !closed else { return }
        var query: [String: String] = [:]
        if let ep = request.episodeId { query["episode"] = ep }
        do {
            let d: PlaybackData = try await api.send(.get, "/playback/\(request.titleId)", query: query)
            data = d
            started = false
            if isPlaying {
                started = true
                report("start")
            }
        } catch {
            let e = APIError.from(error)
            if e.code == "too_many_streams" || e.code == "daily_limit" {
                pause()
                fail(message: e.message, code: e.code)
            }
        }
    }

    // MARK: Interrupciones

    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Llamada, alarma, Siri: iOS ya pausó el audio.
            break
        case .ended:
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if opts.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                play()
            }
        @unknown default:
            break
        }
    }

    // MARK: PiP

    func attach(layer: AVPlayerLayer) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let created: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: layer)
        guard let controller = created else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        pipObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPiPPossible = possible }
        }
    }

    func togglePiP() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    // MARK: Pantalla de bloqueo y Centro de control

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func removeRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand, c.skipBackwardCommand, c.changePlaybackPositionCommand]
            .forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying(force: Bool) {
        guard let d = data else { return }
        if !force && Date().timeIntervalSince(nowPlayingUpdated) < 5 { return }
        nowPlayingUpdated = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: d.episode?.label ?? d.title.title,
            MPMediaItemPropertyArtist: d.episode != nil ? d.title.title : "SPLIVMAX",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: URL?) {
        guard let url, artwork == nil else { return }
        Task {
            guard let image = await ImagePipeline.shared.load(url, maxPixel: 600) else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying(force: true)
        }
    }

    // MARK: Medidor de velocidad y consumo

    private func startMeter() {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self?.sampleNetwork()
                self?.watchdog()
            }
        }
    }

    /// Mide los bytes descargados por segundo según el registro de acceso de AVPlayer.
    private func sampleNetwork() {
        guard !closed, let item = player.currentItem else { return }
        let now = Date()
        let events: [AVPlayerItemAccessLogEvent] = item.accessLog()?.events ?? []
        var total: Int64 = 0
        for event in events where event.numberOfBytesTransferred > 0 {
            total += event.numberOfBytesTransferred
        }
        // observedBitrate es la velocidad real mientras se descarga; los bytes por segundo la subestiman
        // cuando el búfer está lleno (se descarga a ráfagas), así que solo sirven de respaldo.
        var observed: Double = 0
        if let last = events.last, last.observedBitrate > 0 { observed = last.observedBitrate }
        let id = ObjectIdentifier(item)
        if sampledItem == id {
            let delta: Int64 = total - sampledBytes
            let dt: Double = now.timeIntervalSince(sampledAt)
            if delta > 0, dt > 0.2 {
                let sample: Double = max(observed, Double(delta) * 8 / dt)
                if let previous = throughput {
                    throughput = previous * 0.5 + sample * 0.5
                } else {
                    throughput = sample
                }
                sessionBytes += delta
                unsavedBytes += delta
            } else if isBuffering, let current = throughput {
                // Esperando datos sin recibir nada: la conexión real es más lenta de lo que mostraba.
                throughput = current * 0.6
            }
        } else {
            sampledItem = id
        }
        sampledBytes = total
        sampledAt = now
        if throughput == nil, observed > 0 {
            throughput = observed
        }
        let height = Int(item.presentationSize.height.rounded())
        if height > 0, height != videoHeight { videoHeight = height }
        if now.timeIntervalSince(lastUsageFlush) > 15 { flushUsage() }
    }

    private func flushUsage() {
        lastUsageFlush = Date()
        if unsavedBytes > 0 {
            DataUsage.add(bytes: unsavedBytes, cellular: !network.isWiFi)
            unsavedBytes = 0
        }
        if started, let measured = throughput { BandwidthMemory.record(measured, wifi: network.isWiFi) }
    }

    // MARK: Cierre

    func close() {
        guard !closed else { return }
        sampleNetwork()
        flushUsage()
        meterTask?.cancel()
        meterTask = nil
        if started { report("stop") }
        closed = true
        stopHeartbeat()
        pip?.stopPictureInPicture()
        player.pause()
        removeItemObservers()
        playerObservers.forEach { $0.invalidate() }
        playerObservers = []
        pipObserver?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        bag = []
        removeRemoteCommands()
        allowScreenSleep()
        ImagePipeline.shared.videoActive = false
    }

    private func finite(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

extension PlayerController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPiPActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
