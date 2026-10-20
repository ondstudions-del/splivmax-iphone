import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var link: WebLink?
    @State private var confirmLogout = false
    @State private var deleting = false
    @State private var changingPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.isLoggedIn {
                    profileHeader
                    if !session.isKids { PlanCard() }
                    quickLinks
                    if !session.isKids { accountSection }
                } else {
                    guestHeader
                }
                generalSection
                if session.isLoggedIn {
                    Button(role: .destructive) { confirmLogout = true } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.bad))
                    if !session.isKids {
                        Button("Eliminar mi cuenta") { deleting = true }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Theme.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                CreditsFooter()
                Text("Versión \(AppConfig.version)")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.gutter)
            .padding(.bottom, 20)
        }
        .refreshable { await session.refreshMe() }
        .screenBackground()
        .navigationTitle(session.isLoggedIn ? "Perfil" : "Mi SPLIVMAX")
        .navigationBarTitleDisplayMode(.large)
        .task { if session.isLoggedIn { await session.refreshMe() } }
        .sheet(item: $link) { SafariView(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: $deleting) { DeleteAccountSheet() }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .confirmationDialog("¿Cerrar sesión en este iPhone?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { Task { await session.logout() } }
        }
    }

    // MARK: Cabeceras

    private var profileHeader: some View {
        HStack(spacing: 14) {
            AvatarView(url: session.profile?.avatarUrl ?? session.user?.avatarUrl, size: 64, name: session.profile?.name ?? session.user?.name ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Text(session.profile?.name ?? session.user?.name ?? "")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(Theme.text)
                if let user = session.user {
                    Text(user.email).font(.system(size: 13.5)).foregroundColor(Theme.text2).lineLimit(1)
                }
                if session.isKids {
                    Text("Perfil infantil").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.accent2)
                }
            }
            Spacer()
            Button {
                Task { await session.switchProfile() }
            } label: {
                Image(systemName: "person.2.circle")
                    .font(.system(size: 26))
                    .foregroundColor(Theme.accent2)
            }
            .accessibilityLabel(Text("Cambiar de perfil"))
        }
        .panel()
    }

    private var guestHeader: some View {
        VStack(spacing: 14) {
            Image("LogoMark").resizable().scaledToFit().frame(width: 70, height: 70)
                .shadow(color: Theme.accent.opacity(0.5), radius: 18, y: 4)
            Text("Tu cine en casa")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.text)
            Text("Inicia sesión para ver películas y series, guardar tu lista y continuar donde lo dejaste.")
                .font(.system(size: 14.5))
                .foregroundColor(Theme.text2)
                .multilineTextAlignment(.center)
            Button("Iniciar sesión") { _ = session.requireLogin(.login) }
                .buttonStyle(PrimaryButtonStyle())
            if session.registrationOpen {
                Button("Crear una cuenta") { _ = session.requireLogin(.register) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.vertical, 8)
        .panel(padding: 20)
    }

    // MARK: Secciones

    private var quickLinks: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                QuickTile(route: .myList, icon: "heart.fill", title: "Mi lista")
                QuickTile(route: .history, icon: "clock.arrow.circlepath", title: "Historial")
                QuickTile(route: .notifications, icon: "bell.fill", title: "Avisos", badge: session.unread)
            }
            NavigationLink(value: Route.offline) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.gradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ver sin conexión")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.text)
                        Text("Descargas Premium · solo en la app")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.muted)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var accountSection: some View {
        MenuSection(title: "Cuenta") {
            MenuRow(route: .editAccount, icon: "person.text.rectangle", title: "Datos de la cuenta")
            MenuButtonRow(icon: "key", title: "Cambiar contraseña") { changingPassword = true }
            MenuRow(route: .manageProfiles, icon: "person.2", title: "Perfiles")
            MenuRow(route: .devices, icon: "iphone", title: "Dispositivos y sesiones")
            MenuRow(route: .plans, icon: "crown", title: "Planes")
            if AppConfig.billingMode == .direct {
                MenuRow(route: .payments, icon: "creditcard", title: "Pagos")
            }
        }
    }

    private var generalSection: some View {
        MenuSection(title: "General") {
            MenuRow(route: .settings, icon: "gearshape", title: "Ajustes")
            MenuRow(route: .help, icon: "questionmark.circle", title: "Ayuda")
            MenuRow(route: .legalTerms, icon: "doc.text", title: "Términos y condiciones")
            MenuRow(route: .legalPrivacy, icon: "hand.raised", title: "Política de privacidad")
        }
    }
}

// MARK: - Documentos legales (dentro de la app, sin Safari)

struct LegalDocumentView: View {
    enum Kind: String {
        case terms, privacy
        var title: String {
            switch self {
            case .terms: return "Términos y condiciones"
            case .privacy: return "Política de privacidad"
            }
        }
    }

    let kind: Kind
    @State private var heading = ""
    @State private var text = ""
    @State private var loading = true
    @State private var error: APIError?

    var body: some View {
        Group {
            if loading && text.isEmpty {
                LoadingView()
            } else if let error, text.isEmpty {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(heading.isEmpty ? kind.title : heading)
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundColor(Theme.text)
                        Text(text.isEmpty ? "Documento no disponible por ahora." : text)
                            .font(.system(size: 15))
                            .foregroundColor(Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Theme.gutter)
                    .padding(.bottom, 40)
                }
            }
        }
        .screenBackground()
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let r: LegalDocument = try await APIClient.shared.send(.get, "/legal/\(kind.rawValue)", authorized: false)
            heading = r.heading
            text = r.text
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
        loading = false
    }
}

struct LegalDocument: Decodable {
    let heading: String
    let text: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = (try? c.decode(String.self, forKey: .heading)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
    }

    enum CodingKeys: String, CodingKey { case heading, text }
}

// MARK: - Tarjeta del plan

struct PlanCard: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        let sub = session.subscription
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TU PLAN")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(1.2)
                        .foregroundColor(Theme.accent2)
                    Text(sub?.plan.name ?? "Gratis")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                    Text(sub?.statusLabel ?? "Sin suscripción")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(statusColor(sub))
                }
                Spacer()
                if sub?.premium == true { PremiumBadge() }
            }

            if let days = sub?.daysRemaining, sub?.expiresAt != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(days == 1 ? "Queda 1 día" : "Quedan \(days) días")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(days <= 3 ? Theme.warn : Theme.text)
                        Spacer()
                        if let date = ISODate.display(sub?.expiresAt) {
                            Text("Vence el \(date)").font(.system(size: 12.5)).foregroundColor(Theme.text2)
                        }
                    }
                    if let total = sub?.plan.durationDays, total > 0 {
                        ProgressBar(value: Double(days) / Double(total), height: 5)
                    }
                }
            } else if let remaining = sub?.trial.remaining {
                Text("Prueba gratuita: \(remaining) restantes").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.text)
            }

            if let user = session.user {
                HStack(spacing: 6) {
                    Text("ID de usuario").foregroundColor(Theme.muted)
                    Text(user.id).foregroundColor(Theme.text2).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = user.id
                        session.show("ID copiado", .success)
                    } label: {
                        Image(systemName: "doc.on.doc").foregroundColor(Theme.accent2)
                    }
                    .accessibilityLabel(Text("Copiar ID de usuario"))
                }
                .font(.system(size: 12.5, weight: .medium))
            }

            NavigationLink(value: Route.plans) {
                Text(sub?.premium == true ? "Detalles del plan" : (AppConfig.billingMode == .direct ? "Ver planes" : "Detalles de los planes"))
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.32), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .stroke(sub?.premium == true ? AnyShapeStyle(Theme.premiumGradient) : AnyShapeStyle(Theme.line), lineWidth: 1)
        )
    }

    private func statusColor(_ sub: Subscription?) -> Color {
        switch sub?.status {
        case "active", "trial": return Theme.ok
        case "cancelled", "past_due": return Theme.warn
        case "expired": return Theme.bad
        default: return Theme.text2
        }
    }
}

// MARK: - Filas de menú

struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .heavy))
                .kerning(1)
                .foregroundColor(Theme.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}

private struct MenuRowLabel: View {
    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.accent2)
                .frame(width: 26)
            Text(title).font(.system(size: 15.5)).foregroundColor(Theme.text)
            Spacer()
            if let detail { Text(detail).font(.system(size: 14)).foregroundColor(Theme.muted) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.muted)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

struct MenuRow: View {
    let route: Route
    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        NavigationLink(value: route) { MenuRowLabel(icon: icon, title: title, detail: detail) }
            .buttonStyle(.plain)
    }
}

struct MenuButtonRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { MenuRowLabel(icon: icon, title: title) }
            .buttonStyle(.plain)
    }
}

private struct QuickTile: View {
    let route: Route
    let icon: String
    let title: String
    var badge = 0

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.bad, in: Capsule())
                        .padding(8)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Datos de la cuenta

struct EditAccountView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var avatar = "avatar-1"
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?

    private var emailChanged: Bool {
        email.trimmingCharacters(in: .whitespaces).lowercased() != (session.user?.email ?? "").lowercased()
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name).textContentType(.name)
                TextField("Correo electrónico", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if emailChanged {
                    SecureField("Contraseña actual (para cambiar el correo)", text: $password)
                        .textContentType(.password)
                }
            } header: { Text("Tus datos") } footer: {
                if session.user?.emailVerified == false {
                    Text("Tu correo aún no está verificado. Revisa tu bandeja de entrada.")
                }
            }

            Section {
                AvatarPicker(selection: $avatar).padding(.vertical, 6)
            } header: { Text("Avatar de la cuenta") }

            if let user = session.user {
                Section {
                    LabeledContent("ID de usuario", value: user.id)
                    if let since = ISODate.display(user.createdAt) {
                        LabeledContent("Miembro desde", value: since)
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundColor(Theme.bad) }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Datos de la cuenta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Guardar", action: save).disabled(name.trimmingCharacters(in: .whitespaces).count < 2) }
            }
        }
        .onAppear {
            guard let user = session.user, name.isEmpty else { return }
            name = user.name
            email = user.email
            avatar = user.avatar.isEmpty ? "avatar-1" : user.avatar
        }
    }

    private func save() {
        saving = true
        error = nil
        var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "email": email.trimmingCharacters(in: .whitespaces), "avatar": avatar]
        if emailChanged { body["current_password"] = password }
        Task {
            do {
                let r: UserResponse = try await APIClient.shared.send(.post, "/me", body: body)
                session.updateUser(r.user)
                session.show(emailChanged ? "Datos guardados. Te enviamos un correo para verificar la nueva dirección." : "Datos guardados", .success)
                dismiss()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            saving = false
        }
    }
}

struct ChangePasswordSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Contraseña actual", text: $current).textContentType(.password)
                    SecureField("Contraseña nueva", text: $new).textContentType(.newPassword)
                } footer: {
                    Text("Mínimo \(session.minPassword) caracteres. Se cerrarán las demás sesiones abiertas.")
                }
                if let error { Section { Text(error).foregroundColor(Theme.bad) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg2.ignoresSafeArea())
            .navigationTitle("Cambiar contraseña")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Guardar", action: save).disabled(current.isEmpty || new.count < session.minPassword)
                    }
                }
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                let r: MessageResponse = try await APIClient.shared.send(.post, "/me/password", body: ["current_password": current, "password": new])
                session.show(r.message ?? "Contraseña actualizada.", .success)
                dismiss()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            saving = false
        }
    }
}

struct DeleteAccountSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var reason = ""
    @State private var confirm = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Se cerrará tu cuenta, se cancelará tu plan y se solicitará la eliminación de tus datos según la política de privacidad. Esta acción no se puede deshacer.")
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.text2)
                }
                Section {
                    SecureField("Contraseña actual", text: $password).textContentType(.password)
                    TextField("Motivo (opcional)", text: $reason, axis: .vertical).lineLimit(2...4)
                }
                Section {
                    Toggle("Entiendo que mi cuenta se eliminará", isOn: $confirm)
                }
                if let error { Section { Text(error).foregroundColor(Theme.bad) } }
                Section {
                    Button(role: .destructive, action: submit) {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Eliminar mi cuenta").fontWeight(.bold) }
                            Spacer()
                        }
                    }
                    .disabled(password.isEmpty || !confirm || working)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg2.ignoresSafeArea())
            .navigationTitle("Eliminar cuenta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
    }

    private func submit() {
        working = true
        error = nil
        Task {
            do {
                let message = try await session.deleteAccount(password: password, reason: reason)
                dismiss()
                session.show(message, .info)
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            working = false
        }
    }
}

// MARK: - Dispositivos

struct DevicesView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var devices: [Device] = []
    @State private var loading = true
    @State private var error: APIError?

    var body: some View {
        List {
            if let error {
                Section { Text(error.message).foregroundColor(Theme.bad) }
            }
            Section {
                ForEach(devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: icon(device))
                            .font(.system(size: 20))
                            .foregroundColor(Theme.accent2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text).lineLimit(2)
                            Text(detail(device)).font(.system(size: 12.5)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        if device.current {
                            Text("Este").font(.system(size: 11.5, weight: .bold)).foregroundColor(Theme.ok)
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .swipeActions {
                        if !device.current {
                            Button("Cerrar", role: .destructive) { revoke(device) }
                        }
                    }
                }
            } footer: {
                Text("Desliza una sesión hacia la izquierda para cerrarla.")
            }
            if devices.count > 1 {
                Section {
                    Button("Cerrar todas las demás sesiones", role: .destructive, action: revokeOthers)
                        .listRowBackground(Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .overlay { if loading && devices.isEmpty { LoadingView() } }
        .navigationTitle("Dispositivos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let r: ItemsList<Device> = try await APIClient.shared.send(.get, "/me/devices")
            devices = r.items.sorted { $0.current && !$1.current }
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
        loading = false
    }

    private func revoke(_ device: Device) {
        Task {
            do {
                let _: [String: Bool] = try await APIClient.shared.send(.post, "/me/devices/\(device.id)/revoke")
                devices.removeAll { $0.id == device.id }
                session.show("Sesión cerrada", .success)
            } catch {
                session.show(APIError.from(error).message, .error)
            }
        }
    }

    private func revokeOthers() {
        Task {
            do {
                let _: [String: Bool] = try await APIClient.shared.send(.post, "/me/devices/revoke-others")
                await load()
                session.show("Se cerraron las demás sesiones", .success)
            } catch {
                session.show(APIError.from(error).message, .error)
            }
        }
    }

    private func icon(_ d: Device) -> String {
        switch d.platform {
        case "ios": return "iphone"
        case "android": return "candybarphone"
        case "pc": return "desktopcomputer"
        default: return "globe"
        }
    }

    private func detail(_ d: Device) -> String {
        var parts: [String] = [d.app ? "App" : "Navegador"]
        if let seen = ISODate.relative(d.lastSeenAt ?? d.createdAt) { parts.append("Activo \(seen)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @AppStorage(Prefs.dataSaverModeKey) private var dataSaverMode = DataSaverMode.off.rawValue
    @AppStorage(Prefs.subtitleSizeKey) private var subtitleSize = 1
    @AppStorage(Prefs.speedMeterKey) private var speedMeter = false
    @AppStorage(Prefs.preloadKey) private var preload = true
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore
    @State private var cleared = false
    @State private var cellularUsage = DataUsage.cellularBytes
    @State private var wifiUsage = DataUsage.wifiBytes

    var body: some View {
        Form {
            Section {
                Picker("Ahorro de datos", selection: $dataSaverMode) {
                    ForEach(DataSaverMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                HStack {
                    Text("Ahora mismo")
                    Spacer()
                    Label(saverStatus, systemImage: network.prefersLowData ? "leaf.fill" : "sparkles.tv")
                        .foregroundColor(network.prefersLowData ? Theme.ok : Theme.text2)
                        .font(.system(size: 14, weight: .semibold))
                }
            } header: { Text("Ahorro de datos") } footer: {
                Text(dataSaverFooter)
            }

            Section {
                LabeledContent("Con datos móviles", value: DataUsage.format(cellularUsage))
                LabeledContent("Con Wi-Fi", value: DataUsage.format(wifiUsage))
                Button("Reiniciar contador") {
                    DataUsage.reset()
                    cellularUsage = 0
                    wifiUsage = 0
                }
            } header: { Text("Vídeo visto este mes") } footer: {
                Text("Cuenta solo el vídeo reproducido en SPLIVMAX desde este iPhone.")
            }

            Section {
                Picker("Tamaño de subtítulos", selection: $subtitleSize) {
                    Text("Pequeños").tag(0)
                    Text("Normales").tag(1)
                    Text("Grandes").tag(2)
                }
                Toggle("Medidor de velocidad siempre visible", isOn: $speedMeter)
                    .tint(Theme.accent)
                Toggle("Precarga en Wi-Fi", isOn: $preload)
                    .tint(Theme.accent)
                if session.isLoggedIn {
                    NavigationLink(value: Route.manageProfiles) {
                        Text("Reproducción automática y control parental")
                    }
                }
            } header: { Text("Reproducción") } footer: {
                Text("Con la precarga, en Wi-Fi se descargan hasta 5 minutos por delante de lo que estás viendo para que un bajón de la conexión no corte el vídeo (con datos móviles o ahorro de datos no se usa). El medidor muestra la velocidad de tu conexión: rojo por debajo de 1 Mbps, amarillo hasta 2,5 Mbps y verde por encima.")
            }

            Section {
                Button(cleared ? "Caché borrada" : "Borrar caché") {
                    ImagePipeline.shared.clearAll()
                    URLCache.shared.removeAllCachedResponses()
                    APIClient.shared.clearCache()
                    ResponseCache.shared.clear()
                    cleared = true
                    Haptics.success()
                }
                .disabled(cleared)
            } header: { Text("Almacenamiento") } footer: {
                Text("Borra pósteres, catálogo e inicio en caché. Las descargas Offline no se eliminan. El vídeo en streaming no se guarda en Fotos.")
            }

            Section {
                LabeledContent("Versión", value: AppConfig.version)
                LabeledContent("Creado por", value: "OND-S")
            } header: { Text("Acerca de") }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            cellularUsage = DataUsage.cellularBytes
            wifiUsage = DataUsage.wifiBytes
        }
    }

    private var saverStatus: String {
        network.prefersLowData ? "Ahorro activo" : "Calidad automática"
    }

    private var dataSaverFooter: String {
        if network.isConstrained {
            return "El modo Datos reducidos de iOS está activo: SPLIVMAX usa la calidad más ligera automáticamente."
        }
        return "Con el ahorro de datos el vídeo se limita a 480p (unos 0,4 GB por hora en lugar de hasta 3 GB en HD), "
            + "se descarga menos por adelantado y las imágenes se cargan más ligeras."
    }
}

// MARK: - Ayuda

struct HelpView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var link: WebLink?

    private struct FAQ: Identifiable {
        let question: String
        let answer: String
        var id: String { question }
    }

    private let faqs = [
        FAQ(question: "El vídeo se detiene o carga lento", answer: "Activa el ahorro de datos en Ajustes o acércate al router. SPLIVMAX ajusta la calidad a tu conexión automáticamente y la sube cuando la señal mejora."),
        FAQ(question: "¿Puedo descargar películas?", answer: "Por ahora no. Todo el contenido se reproduce en línea, de acuerdo con los derechos de distribución."),
        FAQ(question: "¿Cómo protejo un perfil?", answer: "Ve a Perfil › Perfiles, edita el perfil y ponle un PIN de 4 dígitos."),
        FAQ(question: "¿Dónde veo mi plan?", answer: "En la pestaña Perfil verás tu plan, la fecha de vencimiento y los días que te quedan."),
        FAQ(question: "Olvidé mi contraseña", answer: "En Iniciar sesión toca «¿Olvidaste tu contraseña?» y te enviaremos un enlace a tu correo."),
    ]

    private var supportEmail: String {
        let email = session.config?.site.supportEmail ?? ""
        return email.isEmpty ? AppConfig.supportEmail : email
    }

    var body: some View {
        List {
            Section {
                ForEach(faqs) { faq in
                    DisclosureGroup {
                        Text(faq.answer).font(.system(size: 14.5)).foregroundColor(Theme.text2).padding(.vertical, 4)
                    } label: {
                        Text(faq.question).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    }
                    .listRowBackground(Theme.surface)
                }
            } header: { Text("Preguntas frecuentes") }

            Section {
                Button { open(\.help, "ayuda") } label: { Label("Centro de ayuda", systemImage: "questionmark.circle") }
                Button { open(\.contact, "contacto") } label: { Label("Contactar con soporte", systemImage: "bubble.left.and.bubble.right") }
                if let mail = URL(string: "mailto:\(supportEmail)") {
                    Link(destination: mail) { Label("Escribir a \(supportEmail)", systemImage: "envelope") }
                }
            } header: { Text("Soporte") }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Ayuda")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $link) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private func open(_ path: KeyPath<ServerConfig.Links, String>, _ fallback: String) {
        if let raw = session.config?.links[keyPath: path], let url = URL(string: raw) {
            link = WebLink(url: url)
        } else {
            link = WebLink(url: AppConfig.webURL.appendingPathComponent(fallback))
        }
    }
}
