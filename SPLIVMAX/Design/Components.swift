import SwiftUI
import SafariServices

// MARK: - Insignias y metadatos

struct PremiumBadge: View {
    var small = false

    var body: some View {
        Text("PREMIUM")
            .font(.system(size: small ? 8.5 : 10, weight: .heavy))
            .kerning(0.5)
            .foregroundColor(Color(hex: 0x2A1A00))
            .padding(.horizontal, small ? 5 : 7)
            .padding(.vertical, small ? 2 : 3)
            .background(Theme.premiumGradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SoonBadge: View {
    var body: some View {
        Text("PRONTO")
            .font(.system(size: 8.5, weight: .heavy))
            .kerning(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct AgeBadge: View {
    let rating: String

    var body: some View {
        Text(rating)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.muted.opacity(0.8), lineWidth: 1))
    }
}

struct MetaLine: View {
    let card: TitleCard
    var showPremium = true

    var body: some View {
        HStack(spacing: 9) {
            if let year = card.year { Text(String(year)) }
            if let rating = card.ratingText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundColor(Theme.premium).font(.system(size: 10))
                    Text(rating)
                }
            }
            if let age = card.ageRating, !age.isEmpty { AgeBadge(rating: age) }
            if let d = card.durationText { Text(d) }
            if let s = card.seasonsText { Text(s) }
            if showPremium, card.isPremium { PremiumBadge(small: true) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Theme.text2)
        .lineLimit(1)
    }
}

// MARK: - Tarjetas

struct PosterCard: View {
    let title: TitleCard
    var width: CGFloat? = nil
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if title.isPremium { PremiumBadge(small: true) }
                        if title.isUpcoming { SoonBadge() }
                    }
                    .padding(5)
                }
            if showTitle {
                Text(title.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title.title))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var poster: some View {
        if let width {
            RemoteImage(title.tallImage, maxPixel: 360).frame(width: width, height: (width * 1.5).rounded())
        } else {
            RemoteImage(title.tallImage, maxPixel: 360).aspectRatio(2 / 3, contentMode: .fit)
        }
    }
}

struct TitleRow: View {
    let title: String
    let items: [TitleCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.title(item)) {
                            PosterCard(title: item, width: Layout.posterWidth)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(Theme.text)
            .padding(.horizontal, Theme.gutter)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PosterGrid: View {
    let items: [TitleCard]
    var onReachEnd: (() -> Void)? = nil

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(items) { item in
                NavigationLink(value: Route.title(item)) {
                    PosterCard(title: item)
                }
                .buttonStyle(PressableStyle())
                .onAppear {
                    if item.id == items.last?.id { onReachEnd?() }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

struct ContinueCard: View {
    let item: ContinueItem

    var body: some View {
        let width = Layout.wideCardWidth
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RemoteImage(item.episode?.thumbnail ?? item.title.wideImage, maxPixel: 640)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                if let p = item.progress {
                    VStack {
                        Spacer()
                        ProgressBar(value: Double(p.percent) / 100, height: 3).padding(8)
                    }
                }
            }
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))

            Text(item.title.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.text2)
                .lineLimit(1)
            if let ep = item.episode {
                Text(item.upNext ? "Siguiente: \(ep.code)" : "\(ep.code) · \(ep.title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Theme.gradient)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Visto \(Int(value * 100)) %"))
    }
}

// MARK: - Botones

private struct EnabledOpacity: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.5) }
}

/// Botón principal de la web (.btn--primary): degradado, píldora y sombra.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(Theme.gradient, in: Capsule())
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .modifier(EnabledOpacity())
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// «Reproducir» en móvil: fondo blanco, texto oscuro, radio 10.
struct WhiteButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15.5, weight: .bold))
            .foregroundColor(Theme.heroButtonText)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .modifier(EnabledOpacity())
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Botón translúcido (.btn--glass).
struct GlassButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .modifier(EnabledOpacity())
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Botón secundario sobre superficie (.btn--ghost).
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(tint)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Theme.surface2.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .modifier(EnabledOpacity())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ChipButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(selected ? .white : Theme.text2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if selected { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.surface2) }
                }
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 38
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Formularios

struct SPXField: View {
    let label: String
    @Binding var text: String
    var icon: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var submit: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @State private var reveal = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(Theme.muted)
                .frame(width: 20)
            Group {
                if secure && !reveal {
                    SecureField(label, text: $text)
                } else {
                    TextField(label, text: $text)
                }
            }
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(secure || keyboard == .emailAddress ? .never : .words)
            .autocorrectionDisabled(secure || keyboard == .emailAddress)
            .submitLabel(submit)
            .onSubmit(onSubmit)
            .foregroundColor(Theme.text)
            .font(.system(size: 16))
            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").foregroundColor(Theme.muted)
                }
                .accessibilityLabel(Text(reveal ? "Ocultar contraseña" : "Mostrar contraseña"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct InlineError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(Theme.bad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.bad.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct InlineNotice: View {
    let message: String
    var icon = "checkmark.circle.fill"
    var color: Color = Theme.ok

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Estados

struct LoadingView: View {
    var text: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent2).scaleEffect(1.2)
            if let text {
                Text(text).font(.system(size: 14)).foregroundColor(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: error.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Theme.gradient)
            Text(error.isOffline ? "Sin conexión" : "Algo salió mal")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Theme.text)
            Text(error.message)
                .font(.system(size: 14.5))
                .foregroundColor(Theme.text2)
                .multilineTextAlignment(.center)
            Button("Reintentar", action: retry)
                .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.gradient)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 14.5))
                .foregroundColor(Theme.text2)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Theme.radiusSmall
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.surface2)
            .opacity(dim ? 0.45 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(cornerRadius: 5).frame(width: 150, height: 16).padding(.horizontal, Theme.gutter)
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonBlock().frame(width: Layout.posterWidth, height: Layout.posterWidth * 1.5)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Contenedores

extension View {
    /// Tarjeta con borde (.panel de la web).
    func panel(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    func screenBackground() -> some View {
        self.background(Theme.bg.ignoresSafeArea())
    }
}

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 36
    var name: String = ""

    var body: some View {
        ZStack {
            if url == nil {
                Theme.gradient
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(.white)
            } else {
                RemoteImage(url, maxPixel: size * 3, placeholderIcon: "person.fill")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LogoTitle: View {
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            Text("SPLIVMAX")
                .font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                .kerning(0.8)
                .foregroundColor(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("SPLIVMAX"))
    }
}

// MARK: - Avisos flotantes

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(toast.message)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Theme.surface2.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(.horizontal, 20)
    }

    private var icon: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch toast.kind {
        case .info: return Theme.accent2
        case .success: return Theme.ok
        case .error: return Theme.bad
        }
    }
}

// MARK: - Navegador integrado (ayuda, términos, privacidad)

struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Theme.accent2)
        controller.preferredBarTintColor = UIColor(Theme.bg)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
