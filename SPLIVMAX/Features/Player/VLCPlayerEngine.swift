import Foundation
import UIKit
import Combine

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Motor VLC para Matroska (.mkv) y otros contenedores que AVPlayer no abre en iOS.
@MainActor
final class VLCPlayerEngine: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var failedMessage: String?
    @Published private(set) var rate: Float = 1

#if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
    let drawableView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }()
#else
    let drawableView = UIView()
#endif

    private var tick: Timer?
    private var pendingSeek: Double?
    private var opened = false
    /// Timeout si VLC no entrega el primer fotograma.
    private var startWatchdog: Task<Void, Never>?

    override init() {
        super.init()
#if canImport(MobileVLCKit)
        mediaPlayer.delegate = self
        mediaPlayer.drawable = drawableView
#endif
    }

    func open(url: URL, startAt: Double) {
        failedMessage = nil
        isBuffering = true
        hasVideo = false
        pendingSeek = startAt > 5 ? startAt : nil
        currentTime = max(0, startAt)
        startWatchdog?.cancel()
#if canImport(MobileVLCKit)
        let media = VLCMedia(url: url)
        // Caché corto = primer fotograma más rápido; se amplía al estabilizar.
        media.addOptions([
            "network-caching": NSNumber(value: 800),
            "file-caching": NSNumber(value: 800),
            "live-caching": NSNumber(value: 800),
            "clock-jitter": NSNumber(value: 0),
            "clock-synchro": NSNumber(value: 0),
            "http-reconnect": true,
            "ipv4": true,
            "avcodec-hw": "any",
            "avcodec-fast": true,
            "avcodec-skiploopfilter": NSNumber(value: 1),
            "avcodec-skip-frame": NSNumber(value: 0),
            "avcodec-skip-idct": NSNumber(value: 0),
            "no-audio-time-stretch": true,
        ])
        mediaPlayer.media = media
        mediaPlayer.play()
        opened = true
        startTick()
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.opened && !self.hasVideo && self.failedMessage == nil {
                self.failedMessage = "El vídeo tarda demasiado en abrir. Probando otra fuente…"
                self.isBuffering = false
            }
        }
#else
        failedMessage = "Este build no incluye MobileVLCKit. Abre el proyecto en Xcode y resuelve el paquete SPM."
        isBuffering = false
#endif
    }

    func play() {
#if canImport(MobileVLCKit)
        mediaPlayer.play()
        isPlaying = true
#endif
    }

    func pause() {
#if canImport(MobileVLCKit)
        mediaPlayer.pause()
        isPlaying = false
#endif
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
#if canImport(MobileVLCKit)
        guard duration > 0 else {
            pendingSeek = seconds
            return
        }
        let target = max(0, min(seconds, max(0, duration - 1)))
        let pct = Float(target / duration) * 100
        mediaPlayer.position = pct / 100
        currentTime = target
#endif
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ value: Float) {
        rate = value
#if canImport(MobileVLCKit)
        mediaPlayer.rate = value
#endif
    }

    func stop() {
        startWatchdog?.cancel()
        startWatchdog = nil
        tick?.invalidate()
        tick = nil
#if canImport(MobileVLCKit)
        mediaPlayer.stop()
        mediaPlayer.media = nil
#endif
        opened = false
        isPlaying = false
        isBuffering = false
    }

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
#if canImport(MobileVLCKit)
        guard opened else { return }
        let t = mediaPlayer.time
        if t.intValue > 0 {
            currentTime = Double(t.intValue) / 1000.0
        }
        let len = mediaPlayer.media?.length
        if let len, len.intValue > 0 {
            duration = Double(len.intValue) / 1000.0
        }
        isPlaying = mediaPlayer.isPlaying
        if mediaPlayer.isPlaying {
            isBuffering = false
            if !hasVideo {
                hasVideo = true
                startWatchdog?.cancel()
                // Más caché una vez hay imagen (menos cortes).
                if let media = mediaPlayer.media {
                    media.addOptions([
                        "network-caching": NSNumber(value: 2000),
                        "file-caching": NSNumber(value: 1500),
                    ])
                }
            }
        }
        if let seek = pendingSeek, duration > 0, hasVideo {
            pendingSeek = nil
            self.seek(to: seek)
        }
#endif
    }
}

#if canImport(MobileVLCKit)
extension VLCPlayerEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            guard let player = aNotification.object as? VLCMediaPlayer else { return }
            switch player.state {
            case .playing:
                self.isPlaying = true
                self.isBuffering = false
                self.hasVideo = true
                self.startWatchdog?.cancel()
            case .paused:
                self.isPlaying = false
                self.isBuffering = false
            case .buffering:
                self.isBuffering = true
            case .error:
                self.failedMessage = "No se pudo abrir el archivo de vídeo (MKV)."
                self.isBuffering = false
                self.startWatchdog?.cancel()
            case .ended, .stopped:
                self.isPlaying = false
            default:
                break
            }
        }
    }
}
#endif

import SwiftUI

struct VLCPlayerView: UIViewRepresentable {
    let engine: VLCPlayerEngine

    func makeUIView(context: Context) -> UIView {
        engine.drawableView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
