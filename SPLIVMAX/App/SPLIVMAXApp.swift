import SwiftUI
import UIKit
import AVFoundation

@main
struct SPLIVMAXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore()
    @StateObject private var player = PlayerCoordinator()
    @StateObject private var network = NetworkMonitor.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(network)
                .preferredColorScheme(.dark)
                .tint(Theme.accent2)
                .onAppear {
                    let store = session
                    OfflineDownloadManager.shared.onMessage = { message, isError in
                        store.show(message, isError ? .error : .success)
                    }
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Con la categoría "playback" el vídeo suena aunque el iPhone esté en silencio y permite PiP.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        Appearance.configure()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main,
        ) { _ in
            ImagePipeline.shared.clearMemory()
        }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard identifier == OfflineDownloadManager.sessionIdentifier else {
                completionHandler()
                return
            }
            OfflineDownloadManager.shared.handleBackgroundEvents(completionHandler)
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Vertical para navegar; horizontal y a pantalla completa mientras se ve un vídeo.
@MainActor
enum OrientationController {
    private static var landscape = false

    static func setLandscape(_ on: Bool) {
        landscape = on
        AppDelegate.orientationLock = on ? .landscape : .portrait
        apply()
        // iOS ignora la petición si llega en mitad de una transición (presentación del reproductor).
        Task { @MainActor in
            for delay: UInt64 in [250_000_000, 600_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard landscape == on else { return }
                apply()
            }
        }
    }

    private static func apply() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        guard scene.interfaceOrientation.isLandscape != landscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { _ in }
    }
}

/// Barras del sistema con la identidad de la web (fondo oscuro, texto claro).
enum Appearance {
    static func configure() {
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(Theme.bg).withAlphaComponent(0.92)
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.text), .font: UIFont.systemFont(ofSize: 17, weight: .bold)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.text), .font: UIFont.systemFont(ofSize: 30, weight: .heavy)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Theme.text)

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.accent)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(Theme.text2)], for: .normal)
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).textColor = UIColor(Theme.text)
    }
}
