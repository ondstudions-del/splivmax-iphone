import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Identidad visual de la web (public/assets/css/app.css).
enum Theme {
    static let accent = Color(hex: 0x6D5DFC)
    static let accent2 = Color(hex: 0x00D1FF)
    static let bg = Color(hex: 0x070A12)
    static let bg2 = Color(hex: 0x0C1020)
    static let surface = Color(hex: 0x121730)
    static let surface2 = Color(hex: 0x181E3B)
    static let surface3 = Color(hex: 0x212850)
    static let line = Color(hex: 0x262D52)
    static let text = Color(hex: 0xEEF0FB)
    static let text2 = Color(hex: 0xB3B9D6)
    static let muted = Color(hex: 0x8189AD)
    static let ok = Color(hex: 0x22C993)
    static let warn = Color(hex: 0xF5B041)
    static let bad = Color(hex: 0xFF5778)
    static let premium = Color(hex: 0xFFCF6B)
    static let heroButtonText = Color(hex: 0x0B0F1D)

    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let premiumGradient = LinearGradient(colors: [Color(hex: 0xFFD98A), Color(hex: 0xFFB347)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Sombra inferior de la tarjeta destacada (.hero__shade en móvil).
    static let heroShade = LinearGradient(stops: [
        .init(color: bg.opacity(0.96), location: 0),
        .init(color: bg.opacity(0.55), location: 0.38),
        .init(color: bg.opacity(0), location: 0.65),
    ], startPoint: .bottom, endPoint: .top)

    /// Degradado de la ficha (.detail-hero__shade en móvil).
    static let detailShade = LinearGradient(stops: [
        .init(color: bg, location: 0),
        .init(color: bg.opacity(0), location: 0.55),
    ], startPoint: .bottom, endPoint: .top)

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let radiusLarge: CGFloat = 18
    static let gutter: CGFloat = 12
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

enum Layout {
    static var screenWidth: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let bounds = scenes.first?.screen.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        return min(bounds.width, bounds.height)
    }

    static var screenHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let bounds = scenes.first?.screen.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        return max(bounds.width, bounds.height)
    }

    /// Ancho de póster en filas: ~3,15 tarjetas visibles con 8 pt de separación (como la web).
    static var posterWidth: CGFloat {
        ((screenWidth - Theme.gutter * 2 - 16) / 3.15).rounded(.down)
    }

    static var wideCardWidth: CGFloat {
        ((screenWidth - Theme.gutter * 2 - 8) / 1.7).rounded(.down)
    }
}
