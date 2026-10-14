import SwiftUI
import AVFoundation

@main
struct SPLIVMAXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            // Con la app abierta la pantalla no se apaga sola; fuera de ella vuelve el bloqueo automático.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Con la categoría "playback" el vídeo suena aunque el iPhone esté en silencio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        NotificationManager.shared.configure()
        return true
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
        // iOS ignora la petición si llega en mitad de una transición (carga de página, vídeo a pantalla completa).
        Task { @MainActor in
            for delay: UInt64 in [300_000_000, 600_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard landscape == on else { return }
                apply()
            }
        }
    }

    private static func apply() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let isLandscape = scene.interfaceOrientation.isLandscape
        if #available(iOS 16.0, *) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            guard isLandscape != landscape else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { _ in }
        } else {
            guard isLandscape != landscape else { return }
            let orientation: UIInterfaceOrientation = landscape ? .landscapeRight : .portrait
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
