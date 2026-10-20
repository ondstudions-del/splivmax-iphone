import Foundation

/// Caché en disco de respuestas JSON del catálogo (home, series, filtros, título…).
/// TTL por ruta + reutilización offline (stale) para que la app abra al instante.
final class ResponseCache: @unchecked Sendable {
    static let shared = ResponseCache()

    struct Entry {
        let data: Data
        let storedAt: Date
        let ttl: TimeInterval

        var age: TimeInterval { Date().timeIntervalSince(storedAt) }
        var isFresh: Bool { age <= ttl }
        /// Todavía usable sin red aunque haya pasado el TTL (máx. 24 h).
        var isUsableOffline: Bool { age <= max(ttl * 6, 86_400) }
    }

    private let dir: URL
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private let maxMemoryEntries = 48
    private let maxDiskBytes: Int64 = 80 * 1024 * 1024

    /// Ambito de sesión (perfil / usuario) para no mezclar catálogos entre perfiles.
    var scope: String = "anon" {
        didSet {
            let next = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            scope = next.isEmpty ? "anon" : next
        }
    }

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("spx.api.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trimDiskIfNeeded()
    }

    /// Segundos de frescura; `nil` = no cachear (auth, playback, mutaciones).
    static func ttl(for path: String) -> TimeInterval? {
        let p = path.split(separator: "?").first.map(String.init) ?? path
        if p.hasPrefix("/playback") { return nil }
        if p.hasPrefix("/auth") { return nil }
        if p == "/me" || p.hasPrefix("/me/") { return nil }
        if p.hasPrefix("/profiles") { return nil }
        if p.hasPrefix("/plans") || p.hasPrefix("/trial") || p.hasPrefix("/subscription") { return nil }
        if p.hasPrefix("/account") { return nil }
        switch p {
        case "/home": return 5 * 60
        case "/catalog": return 10 * 60
        case "/filters", "/genres": return 30 * 60
        case "/config": return 60 * 60
        case "/search": return 3 * 60
        case "/favorites", "/my-list", "/history": return 2 * 60
        case "/notifications": return 60
        default:
            if p.hasPrefix("/title/") { return 15 * 60 }
            return nil
        }
    }

    func key(path: String, query: [String: String], authorized: Bool, tokenHint: String?) -> String {
        let items = query.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        let q = items.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let auth = authorized ? (tokenHint.map { String($0.suffix(12)) } ?? "tok") : "pub"
        return "\(scope)|\(auth)|\(path)|\(q)"
    }

    func entry(for key: String) -> Entry? {
        lock.lock()
        if let mem = memory[key] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let url = fileURL(for: key)
        guard let raw = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(DiskWrapper.self, from: raw) else { return nil }
        let entry = Entry(data: wrapper.payload, storedAt: Date(timeIntervalSince1970: wrapper.storedAt), ttl: wrapper.ttl)
        lock.lock()
        memory[key] = entry
        trimMemoryLocked()
        lock.unlock()
        return entry
    }

    func store(key: String, data: Data, ttl: TimeInterval) {
        let entry = Entry(data: data, storedAt: Date(), ttl: ttl)
        lock.lock()
        memory[key] = entry
        trimMemoryLocked()
        lock.unlock()

        let wrapper = DiskWrapper(storedAt: entry.storedAt.timeIntervalSince1970, ttl: ttl, payload: data)
        if let encoded = try? JSONEncoder().encode(wrapper) {
            try? encoded.write(to: fileURL(for: key), options: .atomic)
        }
        trimDiskIfNeeded()
    }

    func clear() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Espacio aproximado usado en disco (bytes).
    func diskUsageBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return sum + size
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = key.data(using: .utf8).map { $0.base64EncodedString() }
            .map { $0.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") }
            ?? UUID().uuidString
        let name = String(digest.prefix(120)) + ".json"
        return dir.appendingPathComponent(name)
    }

    private func trimMemoryLocked() {
        while memory.count > maxMemoryEntries {
            guard let oldest = memory.min(by: { $0.value.storedAt < $1.value.storedAt })?.key else { break }
            memory.removeValue(forKey: oldest)
        }
    }

    private func trimDiskIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        ) else { return }
        var total = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard total > maxDiskBytes else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted {
            guard total > maxDiskBytes * 3 / 4 else { break }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private struct DiskWrapper: Codable {
        let storedAt: TimeInterval
        let ttl: TimeInterval
        let payload: Data
    }
}
