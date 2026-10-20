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
#if canImport(MobileVLCKit)
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 1500,
            "file-caching": 1500,
            "live-caching": 1500,
        ])
        mediaPlayer.media = media
        mediaPlayer.play()
        opened = true
        startTick()
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
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
            if !hasVideo { hasVideo = true }
        }
        if let seek = pendingSeek, duration > 0 {
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
            case .paused:
                self.isPlaying = false
                self.isBuffering = false
            case .buffering:
                self.isBuffering = true
            case .error:
                self.failedMessage = "No se pudo abrir el archivo de vídeo (MKV)."
                self.isBuffering = false
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
