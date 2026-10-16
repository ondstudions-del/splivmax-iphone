import UIKit
import WebKit
import UserNotifications
import BackgroundTasks

extension Notification.Name {
    /// La app debe abrir una URL del sitio (al tocar una notificación).
    static let splivmaxOpenURL = Notification.Name("splivmaxOpenURL")
}

/// Lleva al iPhone las notificaciones del sitio (/api/notifications): las consulta mientras la app está
/// abierta y en segundo plano (cuando iOS lo permite), y muestra las nuevas como notificaciones del sistema.
/// La web también puede enviar notificaciones directamente con window.SPLIVMAXApp.notify(...).
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// URL pendiente de abrir cuando la vista web esté lista (app abierta desde una notificación).
    private(set) var pendingURL: URL?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var checking = false

    private enum Keys {
        static let userAgent = "splivmax.userAgent"
        static let userAgentOS = "splivmax.userAgentOS"
        static let seen = "splivmax.notifications.seen"
        static let primed = "splivmax.notifications.primed"
    }

    private struct Payload: Decodable {
        let ok: Bool
        let unread: Int?
        let items: [Item]?
    }

    private struct Item: Decodable {
        let id: String
        let title: String
        let body: String
        let link: String?
        let read: Bool?
    }

    /// El sitio cierra la sesión si cambia el user agent: las consultas deben enviar exactamente el de la
    /// vista web, y el guardado deja de valer cuando se actualiza iOS (cambia la versión que contiene).
    var userAgent: String? {
        get {
            guard defaults.string(forKey: Keys.userAgentOS) == UIDevice.current.systemVersion else { return nil }
            return defaults.string(forKey: Keys.userAgent)
        }
        set {
            defaults.set(newValue, forKey: Keys.userAgent)
            defaults.set(UIDevice.current.systemVersion, forKey: Keys.userAgentOS)
        }
    }

    /// Se llama al arrancar la app, antes de que termine didFinishLaunching.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.refreshTaskID, using: nil) { task in
            Task { @MainActor in NotificationManager.shared.handleBackgroundRefresh(task) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NotificationManager.shared.startPolling() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                NotificationManager.shared.stopPolling()
                NotificationManager.shared.scheduleBackgroundRefresh()
            }
        }
    }

    // MARK: Consultas al sitio

    /// Mientras se ve un vídeo las consultas se pausan para que toda la conexión sea para el reproductor;
    /// al salir se consulta enseguida para ponerse al día.
    var pausedForPlayback = false {
        didSet {
            guard pausedForPlayback != oldValue else { return }
            if pausedForPlayback {
                stopPolling()
            } else if UIApplication.shared.applicationState == .active {
                startPolling()
            }
        }
    }

    func startPolling() {
        guard !pausedForPlayback else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AppConfig.notificationPollInterval, repeats: true) { _ in
            Task { @MainActor in await NotificationManager.shared.check() }
        }
        Task { await check() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            let ok = await NotificationManager.shared.check()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Descarga las notificaciones del usuario y muestra las que aún no se han visto en este iPhone.
    @discardableResult
    func check() async -> Bool {
        guard !checking, let userAgent = userAgent else { return false }
        checking = true
        defer { checking = false }

        let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let siteCookies = cookies.filter { AppConfig.isInternalHost($0.domain) }
        guard !siteCookies.isEmpty else { return false }

        var request = URLRequest(url: AppConfig.notificationsAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        for (field, value) in HTTPCookie.requestHeaderFields(with: siteCookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        guard let result = try? await Self.session.data(for: request),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              http.url?.path == AppConfig.notificationsAPI.path,
              let payload = try? JSONDecoder().decode(Payload.self, from: result.0), payload.ok else {
            return false
        }
        let items = payload.items ?? []

        await requestAuthorizationIfNeeded()

        let seen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
        if defaults.bool(forKey: Keys.primed) {
            // Del más antiguo al más reciente; como mucho 3 de golpe para no saturar la pantalla.
            let fresh = items.filter { !seen.contains($0.id) && $0.read != true }.prefix(3).reversed()
            for item in fresh {
                deliver(id: "site-\(item.id)", title: item.title, body: item.body, link: item.link)
            }
        }
        // La primera vez sólo se registran las existentes: avisar de notificaciones antiguas sería molesto.
        defaults.set(items.map(\.id), forKey: Keys.seen)
        defaults.set(true, forKey: Keys.primed)
        setBadge(payload.unread ?? items.filter { $0.read != true }.count)
        return true
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Prioridad baja: si coincide con el vídeo, iOS da preferencia al vídeo.
        config.networkServiceType = .background
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: Notificaciones del sistema

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Muestra una notificación ahora o, si se indica la fecha, la programa en el iPhone.
    func deliver(id: String, title: String, body: String, link: String?, at date: Date? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let link, !link.isEmpty { content.userInfo = ["link": link] }

        var trigger: UNNotificationTrigger?
        if let date {
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        }
        let center = UNUserNotificationCenter.current()
        Task {
            await requestAuthorizationIfNeeded()
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func setBadge(_ count: Int) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    // MARK: Abrir el enlace de una notificación

    func open(link: String?) {
        guard let url = AppConfig.resolve(link) else { return }
        pendingURL = url
        NotificationCenter.default.post(name: .splivmaxOpenURL, object: nil)
    }

    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["link"] as? String
        Task { @MainActor in NotificationManager.shared.open(link: link) }
        completionHandler()
    }
}
