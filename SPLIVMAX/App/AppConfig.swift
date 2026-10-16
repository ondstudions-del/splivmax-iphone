import Foundation

/// Datos fijos de la app. La URL de la API y el modo de cobro se pueden cambiar en Info.plist
/// (SPXAPIBaseURL, SPXBillingMode) sin tocar el código.
enum AppConfig {
    static let apiBase: String = {
        let raw = info("SPXAPIBaseURL") ?? "https://splivmax.ond-s.com/api/v1"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }()

    /// Clave de la plataforma iOS (panel > Apps y API). Identifica a la app, no a un usuario.
    static let appKey = "spx_ios_0655dbc3d416ef3800d06b97585846ef74a74077f013a4c9"
    static let platform = "ios"

    static let webURL = URL(string: "https://splivmax.ond-s.com/public/")!
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
