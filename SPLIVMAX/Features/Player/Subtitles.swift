import Foundation

struct SubtitleCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

/// Lector de subtítulos WebVTT (y SRT, por compatibilidad) para pintarlos sobre el vídeo.
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[index].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""),
                  end > start else { continue }
            let text = clean(lines[(index + 1)...].joined(separator: "\n"))
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ value: String) -> Double? {
        let t = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":")
        guard comps.count >= 2 else { return nil }
        var total = 0.0
        for c in comps {
            guard let v = Double(c) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Texto visible en el segundo indicado (búsqueda binaria; admite líneas superpuestas).
    static func caption(in cues: [SubtitleCue], at time: Double) -> String? {
        guard !cues.isEmpty else { return nil }
        var low = 0, high = cues.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { return nil }
        var lines: [String] = []
        var i = found
        while i >= 0 && i >= found - 4 {
            if cues[i].start <= time && cues[i].end >= time { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func load(_ url: URL) async throws -> [SubtitleCue] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError(status: http.statusCode, code: "subtitle", message: "No se pudieron cargar los subtítulos.")
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(text)
    }
}
