import Combine
import Foundation
import UIKit

/// Estado de una descarga para ver sin conexión (solo dentro de la app).
enum OfflineDownloadState: String, Codable, Hashable {
    case queued
    case downloading
    case ready
    case failed
}

/// Rutas de almacenamiento offline (no aisladas a MainActor; usables desde structs y delegates).
enum OfflinePaths {
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SPLIVMAX/Offline", isDirectory: true)
    }

    static var mediaDirectory: URL {
        rootDirectory.appendingPathComponent("Media", isDirectory: true)
    }

    static var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [rootDirectory, mediaDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
    }
}

/// Metadatos de un título o episodio descargado. El vídeo vive en Application Support (no en Fotos).
struct OfflineItem: Identifiable, Codable, Hashable {
    let id: String
    let titleId: String
    var episodeId: String?
    var displayTitle: String
    var subtitle: String?
    var posterURL: String?
    var isEpisode: Bool
    var isMatroska: Bool
    var state: OfflineDownloadState
    var progress: Double
    var localFileName: String?
    var bytesWritten: Int64
    var bytesExpected: Int64
    var errorMessage: String?
    var createdAt: Date
    var taskIdentifier: Int?

    static func makeId(titleId: String, episodeId: String?) -> String {
        if let episodeId, !episodeId.isEmpty { return "\(titleId)_\(episodeId)" }
        return titleId
    }

    var localFileURL: URL? {
        guard let name = localFileName else { return nil }
        let url = OfflinePaths.mediaDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum OfflineDownloadError: LocalizedError {
    case notPremium
    case movieLimit
    case episodeLimit
    case alreadyExists
    case noProgressiveSource
    case notLoggedIn
    case wifiRequired
    case playback(String)

    var errorDescription: String? {
        switch self {
        case .notPremium:
            return "Ver sin conexión es exclusivo de los planes Premium."
        case .movieLimit:
            return "Ya tienes 5 películas descargadas. Elimina una para descargar otra."
        case .episodeLimit:
            return "Ya tienes 5 episodios descargados. Elimina uno para descargar otro."
        case .alreadyExists:
            return "Este contenido ya está en tus descargas."
        case .noProgressiveSource:
            return "Este título solo está disponible en streaming y no se puede descargar."
        case .notLoggedIn:
            return "Inicia sesión para descargar contenido."
        case .wifiRequired:
            return "Activa Wi‑Fi o desactiva «Solo Wi‑Fi» en Ver sin conexión para descargar con datos."
        case .playback(let message):
            return message
        }
    }
}

/// Descarga vídeo en segundo plano (sigue al salir de la app) y lo guarda solo en el sandbox de SPLIVMAX.
@MainActor
final class OfflineDownloadManager: NSObject, ObservableObject {
    static let shared = OfflineDownloadManager()

    static let maxMovies = 5
    static let maxEpisodes = 5
    static let sessionIdentifier = "com.ond.splivmax.offline.downloads"
    static let wifiOnlyKey = "spx.offline.wifiOnly"

    @Published private(set) var items: [OfflineItem] = []

    /// Callback opcional para mostrar toasts (lo enlaza la app con SessionStore).
    var onMessage: ((String, Bool) -> Void)?

    /// Preferir descargas solo por Wi‑Fi (Premium).
    var wifiOnly: Bool {
        get { UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.wifiOnlyKey)
            objectWillChange.send()
        }
    }

    private var session: URLSession!
    private var backgroundCompletion: (() -> Void)?
    private let api = APIClient.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    nonisolated static var rootDirectory: URL { OfflinePaths.rootDirectory }
    nonisolated static var mediaDirectory: URL { OfflinePaths.mediaDirectory }
    private nonisolated static var indexURL: URL { OfflinePaths.indexURL }

    private override init() {
        super.init()
        OfflinePaths.ensureDirectories()
        loadIndex()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Espacio ocupado por descargas listas o en curso.
    var usedBytes: Int64 {
        items.reduce(0) { partial, item in
            if item.bytesExpected > 0, item.state == .downloading || item.state == .queued {
                return partial + item.bytesWritten
            }
            if let url = item.localFileURL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                return partial + size.int64Value
            }
            return partial + max(0, item.bytesWritten)
        }
    }

    var readyCount: Int { items.filter { $0.state == .ready && $0.localFileURL != nil }.count }

    // MARK: Consultas

    func item(titleId: String, episodeId: String? = nil) -> OfflineItem? {
        let id = OfflineItem.makeId(titleId: titleId, episodeId: episodeId)
        return items.first { $0.id == id }
    }

    func isReady(titleId: String, episodeId: String? = nil) -> Bool {
        item(titleId: titleId, episodeId: episodeId)?.state == .ready
            && item(titleId: titleId, episodeId: episodeId)?.localFileURL != nil
    }

    var movieCount: Int {
        items.filter { !$0.isEpisode && $0.state != .failed }.count
    }

    var episodeCount: Int {
        items.filter { $0.isEpisode && $0.state != .failed }.count
    }

    // MARK: Acciones

    func enqueue(
        titleId: String,
        episodeId: String?,
        displayTitle: String,
        subtitle: String?,
        poster: URL?,
        isEpisode: Bool,
        premium: Bool,
        loggedIn: Bool
    ) async {
        do {
            guard loggedIn else { throw OfflineDownloadError.notLoggedIn }
            guard premium else { throw OfflineDownloadError.notPremium }
            if wifiOnly && !NetworkMonitor.shared.isWiFi {
                throw OfflineDownloadError.wifiRequired
            }
            let id = OfflineItem.makeId(titleId: titleId, episodeId: episodeId)
            if let existing = items.first(where: { $0.id == id }), existing.state != .failed {
                throw OfflineDownloadError.alreadyExists
            }
            if isEpisode {
                if episodeCount >= Self.maxEpisodes { throw OfflineDownloadError.episodeLimit }
            } else if movieCount >= Self.maxMovies {
                throw OfflineDownloadError.movieLimit
            }

            var query: [String: String] = [:]
            if let episodeId, !episodeId.isEmpty { query["episode"] = episodeId }
            let playback: PlaybackData = try await api.send(.get, "/playback/\(titleId)", query: query)
            guard let source = Self.bestDownloadSource(playback.sources) else {
                throw OfflineDownloadError.noProgressiveSource
            }

            items.removeAll { $0.id == id && $0.state == .failed }
            var item = OfflineItem(
                id: id,
                titleId: titleId,
                episodeId: episodeId,
                displayTitle: displayTitle,
                subtitle: subtitle ?? playback.episode?.label,
                posterURL: poster?.absoluteString,
                isEpisode: isEpisode,
                isMatroska: source.isMatroska,
                state: .queued,
                progress: 0,
                localFileName: nil,
                bytesWritten: 0,
                bytesExpected: 0,
                errorMessage: nil,
                createdAt: Date(),
                taskIdentifier: nil
            )
            items.insert(item, at: 0)
            persist()

            var request = URLRequest(url: source.url)
            request.timeoutInterval = 120
            let task = session.downloadTask(with: request)
            task.taskDescription = id
            task.priority = URLSessionTask.highPriority
            item.taskIdentifier = task.taskIdentifier
            item.state = .downloading
            upsert(item)
            task.resume()
            let quality = source.label.isEmpty ? "\(source.quality)p" : source.label
            notify("Descargando \(quality). Puede continuar en segundo plano.", error: false)
        } catch let e as OfflineDownloadError {
            notify(e.localizedDescription, error: true)
        } catch {
            notify(APIError.from(error).message, error: true)
        }
    }

    private func notify(_ message: String, error: Bool) {
        onMessage?(message, error)
    }

    func cancel(_ id: String) {
        if let item = items.first(where: { $0.id == id }), let tid = item.taskIdentifier {
            session.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == tid }?.cancel()
            }
        }
        remove(id)
    }

    func remove(_ id: String) {
        if let item = items.first(where: { $0.id == id }) {
            if let name = item.localFileName {
                try? FileManager.default.removeItem(at: OfflinePaths.mediaDirectory.appendingPathComponent(name))
            }
            if let tid = item.taskIdentifier {
                session.getAllTasks { tasks in
                    tasks.first { $0.taskIdentifier == tid }?.cancel()
                }
            }
        }
        items.removeAll { $0.id == id }
        persist()
    }

    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }

    // MARK: Persistencia

    private func loadIndex() {
        guard let data = try? Data(contentsOf: OfflinePaths.indexURL),
              let decoded = try? decoder.decode([OfflineItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.map { item in
            var copy = item
            if copy.state == .ready, copy.localFileURL == nil {
                copy.state = .failed
                copy.errorMessage = "Archivo no encontrado"
            }
            if copy.state == .downloading || copy.state == .queued {
                // Tras reinicio el sistema puede reanudar; si no, queda en cola visible.
            }
            return copy
        }
    }

    private func persist() {
        OfflinePaths.ensureDirectories()
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: OfflinePaths.indexURL, options: .atomic)
    }

    private func upsert(_ item: OfflineItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.insert(item, at: 0)
        }
        persist()
    }

    private func update(id: String, _ block: (inout OfflineItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        block(&item)
        items[i] = item
        persist()
    }

    /// Prefiere MP4 progresivo de mejor calidad; MKV como respaldo. HLS no se descarga aquí.
    static func bestDownloadSource(_ sources: [PlaybackSource]) -> PlaybackSource? {
        let progressive = sources.filter { !$0.hls }.sorted { $0.quality > $1.quality }
        if let mp4 = progressive.first(where: { !$0.isMatroska }) { return mp4 }
        return progressive.first
    }

    /// Elimina archivos huérfanos que ya no están en el índice.
    func pruneOrphans() {
        OfflinePaths.ensureDirectories()
        let known = Set(items.compactMap(\.localFileName))
        guard let files = try? FileManager.default.contentsOfDirectory(at: OfflinePaths.mediaDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files where !known.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func finishBackgroundIfNeeded() {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        handler?()
    }
}

// MARK: - URLSession (segundo plano)

extension OfflineDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription
        Task { @MainActor in
            guard let id else { return }
            self.update(id: id) { item in
                item.state = .downloading
                item.bytesWritten = totalBytesWritten
                item.bytesExpected = totalBytesExpectedToWrite
                if totalBytesExpectedToWrite > 0 {
                    item.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                }
                item.taskIdentifier = downloadTask.taskIdentifier
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // El archivo temporal del sistema desaparece al salir del delegate: hay que copiarlo ya.
        let id = downloadTask.taskDescription ?? ""
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("spx_\(id.isEmpty ? "x" : id)_\(UUID().uuidString)")
        try? FileManager.default.copyItem(at: location, to: staging)

        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: staging) }
            guard !id.isEmpty, var item = self.items.first(where: { $0.id == id }) else { return }
            guard FileManager.default.fileExists(atPath: staging.path) else {
                item.state = .failed
                item.errorMessage = "No se pudo recibir el archivo."
                item.taskIdentifier = nil
                self.upsert(item)
                return
            }
            OfflinePaths.ensureDirectories()
            let ext = item.isMatroska ? "mkv" : "mp4"
            let name = "\(id).\(ext)"
            let dest = OfflinePaths.mediaDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: staging, to: dest)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = dest
                try? mutable.setResourceValues(values)
                item.localFileName = name
                item.state = .ready
                item.progress = 1
                item.errorMessage = nil
                item.taskIdentifier = nil
                self.upsert(item)
            } catch {
                item.state = .failed
                item.errorMessage = "No se pudo guardar el vídeo."
                item.taskIdentifier = nil
                self.upsert(item)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription
        Task { @MainActor in
            guard let id, let error else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.update(id: id) { item in
                if item.state != .ready {
                    item.state = .failed
                    item.errorMessage = APIError.from(error).message
                    item.taskIdentifier = nil
                }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.finishBackgroundIfNeeded()
        }
    }
}
