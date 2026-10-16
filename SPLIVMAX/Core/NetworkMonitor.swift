import Foundation
import Network

/// Estado de la conexión: sin red, modo datos reducidos (constrained) o red de pago (expensive).
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    @Published private(set) var isConstrained = false
    @Published private(set) var isExpensive = false
    @Published private(set) var isWiFi = false

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isConstrained != constrained { self.isConstrained = constrained }
                if self.isExpensive != expensive { self.isExpensive = expensive }
                if self.isWiFi != wifi { self.isWiFi = wifi }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ondstudios.splivmax.network", qos: .utility))
    }

    /// Ahorro de datos: lo pide el usuario o lo activa iOS (modo datos reducidos).
    var prefersLowData: Bool {
        isConstrained || UserDefaults.standard.bool(forKey: Prefs.dataSaverKey)
    }
}

enum Prefs {
    static let dataSaverKey = "spx.dataSaver"
    static let cellularHDKey = "spx.cellularHD"
    static let recentSearchesKey = "spx.recentSearches"
    static let subtitleSizeKey = "spx.subtitleSize"
}
