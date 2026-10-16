import SwiftUI

/// Hoja de acceso: iniciar sesión, crear cuenta o recuperar la contraseña.
struct AuthSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var link: WebLink?
    @State private var prefillEmail = ""
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let notice { InlineNotice(message: notice) }
                    switch session.authMode {
                    case .login:
                        LoginForm(email: prefillEmail)
                    case .register:
                        RegisterForm(openLink: { link = WebLink(url: $0) }, onPendingVerification: { email, message in
                            prefillEmail = email
                            notice = message
                            session.authMode = .login
                        })
                    case .forgot:
                        ForgotForm()
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .animation(.easeInOut(duration: 0.25), value: session.authMode)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }.foregroundColor(Theme.text2)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $link) { SafariView(url: $0.url).ignoresSafeArea() }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .shadow(color: Theme.accent.opacity(0.55), radius: 18, y: 4)
            Text(title)
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(Theme.text)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundColor(Theme.text2)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 6)
    }

    private var title: String {
        switch session.authMode {
        case .login: return "Inicia sesión"
        case .register: return "Crea tu cuenta"
        case .forgot: return "Recupera tu acceso"
        }
    }

    private var subtitle: String {
        switch session.authMode {
        case .login: return "Sigue viendo tus películas y series donde las dejaste."
        case .register: return "Regístrate gratis y empieza a disfrutar de SPLIVMAX."
        case .forgot: return "Te enviaremos un enlace para crear una contraseña nueva."
        }
    }
}

private struct LoginForm: View {
    @EnvironmentObject private var session: SessionStore
    @State var email: String
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?

    private var valid: Bool { email.contains("@") && !password.isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            SPXField(label: "Correo electrónico", text: $email, icon: "envelope", keyboard: .emailAddress, contentType: .username)
            SPXField(label: "Contraseña", text: $password, icon: "lock", secure: true, contentType: .password, submit: .go, onSubmit: submit)
            if let error { InlineError(message: error) }

            Button(action: submit) {
                ZStack {
                    Text("Iniciar sesión").opacity(loading ? 0 : 1)
                    if loading { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!valid || loading)
            .padding(.top, 4)

            Button("¿Olvidaste tu contraseña?") { session.authMode = .forgot }
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(Theme.accent2)

            if session.registrationOpen {
                VStack(spacing: 10) {
                    Divider().overlay(Theme.line).padding(.vertical, 8)
                    Text("¿Nuevo en SPLIVMAX?")
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.text2)
                    Button("Crear una cuenta") { session.authMode = .register }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func submit() {
        guard valid, !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                try await session.login(email: email, password: password)
                Haptics.success()
            } catch {
                self.error = APIError.from(error).fullMessage
                Haptics.error()
            }
            loading = false
        }
    }
}

private struct RegisterForm: View {
    @EnvironmentObject private var session: SessionStore
    let openLink: (URL) -> Void
    let onPendingVerification: (String, String) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var accept = false
    @State private var loading = false
    @State private var error: String?

    private var valid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && email.contains("@") && password.count >= session.minPassword && accept
    }

    var body: some View {
        VStack(spacing: 14) {
            SPXField(label: "Nombre", text: $name, icon: "person", contentType: .name)
            SPXField(label: "Correo electrónico", text: $email, icon: "envelope", keyboard: .emailAddress, contentType: .username)
            SPXField(label: "Contraseña", text: $password, icon: "lock", secure: true, contentType: .newPassword, submit: .done)
            Text("Mínimo \(session.minPassword) caracteres. Usa una frase que puedas recordar.")
                .font(.system(size: 12.5))
                .foregroundColor(password.isEmpty || password.count >= session.minPassword ? Theme.muted : Theme.warn)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $accept) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Acepto los términos y la política de privacidad")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                    HStack(spacing: 14) {
                        Button("Términos") { openLink(link(\.terms, "terminos")) }
                        Button("Privacidad") { openLink(link(\.privacy, "privacidad")) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent2)
                    .buttonStyle(.plain)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            .padding(.vertical, 4)

            if let error { InlineError(message: error) }

            Button(action: submit) {
                ZStack {
                    Text("Crear cuenta").opacity(loading ? 0 : 1)
                    if loading { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!valid || loading)

            Button("Ya tengo cuenta") { session.authMode = .login }
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(Theme.accent2)
                .padding(.top, 4)
        }
    }

    private func link(_ path: KeyPath<ServerConfig.Links, String>, _ fallback: String) -> URL {
        if let raw = session.config?.links[keyPath: path], let url = URL(string: raw) { return url }
        return AppConfig.webURL.appendingPathComponent(fallback)
    }

    private func submit() {
        guard valid, !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                if let message = try await session.register(name: name, email: email, password: password) {
                    onPendingVerification(email, message)
                }
                Haptics.success()
            } catch {
                self.error = APIError.from(error).fullMessage
                Haptics.error()
            }
            loading = false
        }
    }
}

private struct ForgotForm: View {
    @EnvironmentObject private var session: SessionStore
    @State private var email = ""
    @State private var loading = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            SPXField(label: "Correo electrónico", text: $email, icon: "envelope", keyboard: .emailAddress, contentType: .username, submit: .send, onSubmit: submit)
            if let message { InlineNotice(message: message) }
            if let error { InlineError(message: error) }
            Button(action: submit) {
                ZStack {
                    Text("Enviar enlace").opacity(loading ? 0 : 1)
                    if loading { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!email.contains("@") || loading)

            Button("Volver a iniciar sesión") { session.authMode = .login }
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(Theme.accent2)
                .padding(.top, 4)
        }
    }

    private func submit() {
        guard email.contains("@"), !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                message = try await session.forgotPassword(email: email)
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            loading = false
        }
    }
}
