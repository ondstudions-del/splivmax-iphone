import SwiftUI

/// Pantalla de bienvenida animada mientras carga el sitio por primera vez.
struct SplashView: View {
    @State private var pulse = false
    @State private var waves = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            AppConfig.background

            RadialGradient(colors: [AppConfig.accent.opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: 300)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .offset(y: -40)

            RadialGradient(colors: [AppConfig.accent2.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 420)

            VStack(spacing: 26) {
                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(AppConfig.brandGradient, lineWidth: 2)
                            .frame(width: 112, height: 112)
                            .scaleEffect(waves ? 2.4 : 0.9)
                            .opacity(waves ? 0 : 0.55)
                            .animation(.easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(Double(i) * 0.7), value: waves)
                    }

                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 108, height: 108)
                        .shadow(color: AppConfig.accent.opacity(0.65), radius: 28, y: 6)
                        .scaleEffect(pulse ? 1.0 : 0.94)
                }

                VStack(spacing: 6) {
                    Text("SPLIVMAX")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .kerning(1.5)
                        .foregroundColor(.white)
                    Text("STREAMING")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(6)
                        .foregroundColor(.white.opacity(0.55))
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { pulse = true }
            waves = true
        }
    }
}
