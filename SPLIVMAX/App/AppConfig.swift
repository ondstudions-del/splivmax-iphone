import Foundation

/// Datos fijos de la app. La URL de la API y el modo de cobro se pueden cambiar en Info.plist
/// (SPXAPIBaseURL, SPXBillingMode) sin tocar el código.
enum AppConfig {
    static let apiBase: String = {
        let raw = info("SPXAPIBaseURL") ?? "https://splivmax.ond-s.com/v1"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }()

    /// Clave de la plataforma iOS (panel › Apps y API). Identifica a la app, no a un usuario.
    static let appKey = "onds_ios_ac4634b003b8fe565a5eb8b9efbdd5b0442338ee4ea1c040"
    static let platform = "ios"
    /// Capacidad del reproductor nativo (VLC / Matroska).
    static let playerCapabilities = "mkv,vlc,hls,mp4"

    static let webURL = URL(string: "https://splivmax.ond-s.com/")!
    static let supportEmail = "ondstudions@gmail.com"

    /// reader: versión App Store, sin compras ni enlaces de pago (norma 3.1.3(a) de Apple).
    /// direct: pago manual por transferencia (Nequi, Bre-B, Llave) vía API; sólo fuera del App Store.
    static let billingMode: BillingMode = BillingMode(rawValue: info("SPXBillingMode") ?? "") ?? .reader

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }
}

enum BillingMode: String {
    case reader, direct
}
