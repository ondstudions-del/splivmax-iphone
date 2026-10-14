import SwiftUI
import AVFoundation

@main
struct SPLIVMAXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Con la categoría "playback" el vídeo suena aunque el iPhone esté en silencio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Vertical para navegar; horizontal y a pantalla completa dentro del reproductor.
enum OrientationController {
    static func setPlayerMode(_ on: Bool) {
        AppDelegate.orientationLock = on ? .landscape : .portrait
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        if #available(iOS 16.0, *) {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait)) { _ in }
        } else {
            let orientation: UIInterfaceOrientation = on ? .landscapeRight : .portrait
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
