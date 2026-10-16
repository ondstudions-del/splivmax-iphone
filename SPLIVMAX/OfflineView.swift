import SwiftUI

struct OfflineView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            AppConfig.background.ignoresSafeArea()
            RadialGradient(colors: [AppConfig.accent.opacity(0.25), .clear], center: .center, startRadius: 4, endRadius: 280)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 104, height: 104)
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(AppConfig.brandGradient)
                }

                Text("Sin conexión")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text("Revisa tu conexión a internet.\nVolveremos a intentarlo en cuanto vuelva la señal.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)

                Button(action: retry) {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(AppConfig.brandGradient))
                        .shadow(color: AppConfig.accent.opacity(0.5), radius: 14, y: 6)
                }
                .padding(.top, 8)
            }
            .padding(32)
        }
    }
}
