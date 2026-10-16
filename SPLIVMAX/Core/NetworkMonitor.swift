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
    /// Ahorro de datos en uso ahora mismo (según el modo elegido y la red actual).
    @Published private(set) var prefersLowData = false

    private let monitor = NWPathMonitor()
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        DataSaverMode.migrate()
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
                self.updateLowData()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ondstudios.splivmax.network", qos: .utility))
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateLowData() }
        }
        updateLowData()
    }

    var dataSaverMode: DataSaverMode { DataSaverMode.current }

    private func updateLowData() {
        let mode = DataSaverMode.current
        let low = isConstrained || mode == .always || (mode == .cellular && !isWiFi && isOnline)
        if prefersLowData != low { prefersLowData = low }
        ImagePipeline.shared.lowData = low
    }
}

enum Prefs {
    static let dataSaverKey = "spx.dataSaver"
    static let dataSaverModeKey = "spx.dataSaverMode"
    static let speedMeterKey = "spx.speedMeter"
    static let cellularHDKey = "spx.cellularHD"
    static let recentSearchesKey = "spx.recentSearches"
    static let subtitleSizeKey = "spx.subtitleSize"
}

/// Ahorro de datos: desactivado, solo con datos móviles o siempre.
enum DataSaverMode: Int, CaseIterable, Identifiable {
    case off = 0, cellular = 1, always = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Desactivado"
        case .cellular: return "Solo con datos móviles"
        case .always: return "Siempre"
        }
    }

    static var current: DataSaverMode {
        DataSaverMode(rawValue: UserDefaults.standard.integer(forKey: Prefs.dataSaverModeKey)) ?? .off
    }

    /// La versión anterior guardaba un interruptor (sí/no).
    static func migrate() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Prefs.dataSaverModeKey) == nil else { return }
        defaults.set(defaults.bool(forKey: Prefs.dataSaverKey) ? DataSaverMode.always.rawValue : DataSaverMode.off.rawValue,
                     forKey: Prefs.dataSaverModeKey)
    }
}

/// Datos de vídeo descargados este mes, separados por red (se reinicia cada mes).
enum DataUsage {
    private static let monthKey = "spx.usage.month"
    private static let cellularKey = "spx.usage.cellular"
    private static let wifiKey = "spx.usage.wifi"

    private static var month: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    private static func rollover() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: monthKey) != month {
            defaults.set(month, forKey: monthKey)
            defaults.set(0.0, forKey: cellularKey)
            defaults.set(0.0, forKey: wifiKey)
        }
    }

    static func add(bytes: Int64, cellular: Bool) {
        guard bytes > 0 else { return }
        rollover()
        let key = cellular ? cellularKey : wifiKey
        UserDefaults.standard.set(UserDefaults.standard.double(forKey: key) + Double(bytes), forKey: key)
    }

    static var cellularBytes: Double { rollover(); return UserDefaults.standard.double(forKey: cellularKey) }
    static var wifiBytes: Double { rollover(); return UserDefaults.standard.double(forKey: wifiKey) }

    static func reset() {
        UserDefaults.standard.set(month, forKey: monthKey)
        UserDefaults.standard.set(0.0, forKey: cellularKey)
        UserDefaults.standard.set(0.0, forKey: wifiKey)
    }

    static func format(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Última velocidad medida en cada tipo de red: el reproductor arranca con una calidad que la conexión aguanta.
enum BandwidthMemory {
    private static func key(_ wifi: Bool) -> String { wifi ? "spx.bw.wifi" : "spx.bw.cell" }

    static func estimate(wifi: Bool) -> Double? {
        let value = UserDefaults.standard.double(forKey: key(wifi))
        return value > 0 ? value : nil
    }

    static func record(_ bitsPerSecond: Double, wifi: Bool) {
        guard bitsPerSecond.isFinite, bitsPerSecond > 50_000 else { return }
        let previous = estimate(wifi: wifi) ?? bitsPerSecond
        UserDefaults.standard.set(previous * 0.4 + bitsPerSecond * 0.6, forKey: key(wifi))
    }
}

/// Formato del medidor: «850 Kbps», «3,2 Mbps».
enum Speed {
    static func text(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond < 1_000_000 {
            return "\(Int((bitsPerSecond / 1000).rounded())) Kbps"
        }
        let mbps = bitsPerSecond / 1_000_000
        let f = NumberFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.minimumFractionDigits = mbps < 10 ? 1 : 0
        f.maximumFractionDigits = mbps < 10 ? 1 : 0
        return (f.string(from: NSNumber(value: mbps)) ?? String(format: "%.1f", mbps)) + " Mbps"
    }

    enum Level { case low, medium, high }

    static func level(_ bitsPerSecond: Double) -> Level {
        if bitsPerSecond < 1_000_000 { return .low }
        if bitsPerSecond < 2_500_000 { return .medium }
        return .high
    }
}
