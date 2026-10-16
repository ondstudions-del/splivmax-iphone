import SwiftUI

struct ContentView: View {
    @StateObject private var model = WebViewModel()
    @State private var showSplash = true

    var body: some View {
        ZStack(alignment: .top) {
            AppConfig.background.ignoresSafeArea()

            WebView(webView: model.webView)
                .ignoresSafeArea()

            if model.isLoading && model.hasLoadedOnce && !model.isImmersive {
                LoadingBar(progress: model.progress)
                    .transition(.opacity)
            }

            if model.isOffline {
                OfflineView(retry: model.retry)
                    .transition(.opacity)
                    .zIndex(5)
            }

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.06)))
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.isImmersive)
        .modifier(SystemOverlaysHidden(hidden: model.isImmersive))
        .animation(.easeInOut(duration: 0.25), value: model.isOffline)
        .animation(.easeInOut(duration: 0.2), value: model.isLoading)
        .onChange(of: model.hasLoadedOnce) { loaded in
            if loaded { hideSplash(after: 0.25) }
        }
        .onChange(of: model.isOffline) { offline in
            if offline { hideSplash() }
        }
        .task {
            // Si la red es muy lenta, no dejamos al usuario mirando el logo para siempre.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            hideSplash()
        }
    }

    private func hideSplash(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard showSplash else { return }
            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
        }
    }
}

/// Barra fina con el degradado de la marca mientras carga una pÃ¡gina.
struct LoadingBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(AppConfig.brandGradient)
                .frame(width: max(24, geo.size.width * progress), height: 3)
                .shadow(color: AppConfig.accent2.opacity(0.7), radius: 4)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}

/// Oculta el indicador de inicio dentro del reproductor (iOS 16+).
private struct SystemOverlaysHidden: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            content
        }
    }
}
