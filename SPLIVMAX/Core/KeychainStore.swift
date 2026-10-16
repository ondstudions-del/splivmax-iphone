import Foundation
import Security

/// Token de sesión e identificador del dispositivo en el llavero de iOS (cifrado por el sistema).
/// La contraseña del usuario nunca se guarda: sólo se envía al iniciar sesión.
enum KeychainStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.ondstudios.splivmax") + ".session"

    static func string(_ key: String) -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        let query = base(key)
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Identificador propio de la app (no es el IDFA ni sirve para publicidad). El servidor lo usa
    /// para no repetir la prueba gratuita en el mismo iPhone.
    static var deviceId: String {
        if let id = string("device_id") { return id }
        let id = UUID().uuidString.lowercased()
        set(id, for: "device_id")
        return id
    }

    private static func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
