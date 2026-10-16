import SwiftUI

// MARK: - Avatares

@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    @Published private(set) var avatars: [Avatar] = []

    func load() async {
        guard avatars.isEmpty else { return }
        if let r: ItemsList<Avatar> = try? await APIClient.shared.send(.get, "/avatars") {
            avatars = r.items
        }
    }
}

struct AvatarPicker: View {
    @Binding var selection: String
    @StateObject private var store = AvatarStore.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        Group {
            if store.avatars.isEmpty {
                ProgressView().tint(Theme.accent2).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.avatars) { avatar in
                        Button {
                            Haptics.select()
                            selection = avatar.id
                        } label: {
                            RemoteImage(avatar.url, maxPixel: 240, placeholderIcon: "person.fill")
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(selection == avatar.id ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear), lineWidth: 3)
                                )
                                .scaleEffect(selection == avatar.id ? 1.04 : 1)
                                .animation(.spring(response: 0.3), value: selection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(avatar.label.isEmpty ? "Avatar" : avatar.label))
                        .accessibilityAddTraits(selection == avatar.id ? .isSelected : [])
                    }
                }
            }
        }
        .task { await store.load() }
    }
}

// MARK: - Primer perfil

struct ProfileSetupView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var name = ""
    @State private var avatar = "avatar-1"
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    LogoTitle(size: 30)
                    Text("Crea tu perfil")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(Theme.text)
                        .padding(.top, 12)
                    Text("Elige un nombre y un avatar. Luego podrás añadir perfiles para tu familia.")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.text2)
                }
                SPXField(label: "Nombre del perfil", text: $name, icon: "person", contentType: .nickname, submit: .done)
                Text("Avatar").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                AvatarPicker(selection: $avatar)
                if let error { InlineError(message: error) }
                Button(action: submit) {
                    ZStack {
                        Text("Continuar").opacity(loading ? 0 : 1)
                        if loading { ProgressView().tint(.white) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)

                Button("Cerrar sesión") { Task { await session.logout() } }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .onAppear {
            if name.isEmpty, let first = session.user?.name.split(separator: " ").first {
                name = String(first.prefix(30))
            }
        }
    }

    private func submit() {
        loading = true
        error = nil
        Task {
            do {
                try await session.completeSetup(name: name.trimmingCharacters(in: .whitespaces), avatar: avatar)
                Haptics.success()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            loading = false
        }
    }
}

// MARK: - ¿Quién está viendo?

struct ProfilePickerView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var pinFor: Profile?
    @State private var busy: String?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 22)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .top, startRadius: 10, endRadius: 460)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    LogoTitle(size: 28).padding(.top, 24)
                    Text("¿Quién está viendo?")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(Theme.text)

                    if session.profilesData == nil {
                        ProgressView().tint(Theme.accent2).padding(40)
                    }

                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(session.profiles) { profile in
                            Button { choose(profile) } label: {
                                ProfileTile(profile: profile, busy: busy == profile.id)
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(busy != nil || !profile.available)
                        }
                    }
                    .padding(.horizontal, 24)

                    if let error { InlineError(message: error).padding(.horizontal, 24) }

                    HStack(spacing: 18) {
                        if session.profile != nil {
                            Button("Cancelar") { session.cancelProfileChoice() }
                        }
                        Button("Cerrar sesión") { Task { await session.logout() } }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.muted)
                    .padding(.bottom, 30)
                }
            }
        }
        .task { if session.profilesData == nil { await session.loadProfiles() } }
        .sheet(item: $pinFor) { profile in
            PinSheet(title: "PIN de \(profile.name)", message: "Este perfil está protegido. Escribe su PIN de 4 dígitos.") { pin in
                try await session.select(profile: profile.id, pin: pin)
            }
            .presentationDetents([.medium])
        }
    }

    private func choose(_ profile: Profile) {
        error = nil
        if profile.locked {
            pinFor = profile
            return
        }
        busy = profile.id
        Task {
            do {
                try await session.select(profile: profile.id, pin: nil)
                Haptics.success()
            } catch let e as APIError where e.code == "pin_required" {
                pinFor = profile
            } catch {
                self.error = APIError.from(error).message
            }
            busy = nil
        }
    }
}

struct ProfileTile: View {
    let profile: Profile
    var busy = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                AvatarView(url: profile.avatarUrl, size: 112, name: profile.name)
                if busy {
                    Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 112, height: 112)
            .overlay(alignment: .bottomTrailing) {
                if profile.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Theme.surface3, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .opacity(profile.available ? 1 : 0.4)

            VStack(spacing: 3) {
                Text(profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                if profile.kids {
                    Text("Infantil").font(.system(size: 11.5, weight: .bold)).foregroundColor(Theme.accent2)
                } else if !profile.available {
                    Text("En pausa").font(.system(size: 11.5, weight: .bold)).foregroundColor(Theme.warn)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(profile.name + (profile.locked ? ", con PIN" : "") + (profile.kids ? ", infantil" : "")))
    }
}

// MARK: - PIN

struct PinSheet: View {
    let title: String
    let message: String
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    @State private var loading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Theme.line).frame(width: 40, height: 5).padding(.top, 10)
            Text(title).font(.system(size: 21, weight: .heavy)).foregroundColor(Theme.text)
            Text(message)
                .font(.system(size: 14.5))
                .foregroundColor(Theme.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ZStack {
                TextField("", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: pin) { value in
                        let digits = String(value.filter(\.isNumber).prefix(4))
                        if digits != value { pin = digits }
                        if digits.count == 4 { submit() }
                    }
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.surface2)
                            .frame(width: 54, height: 62)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(i == pin.count ? Theme.accent2 : Theme.line, lineWidth: i == pin.count ? 2 : 1)
                            )
                            .overlay {
                                if i < pin.count {
                                    Circle().fill(Theme.text).frame(width: 12, height: 12)
                                }
                            }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("PIN, \(pin.count) de 4 dígitos"))

            if loading { ProgressView().tint(Theme.accent2) }
            if let error { InlineError(message: error).padding(.horizontal, 24) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg2.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func submit() {
        guard !loading else { return }
        loading = true
        error = nil
        let value = pin
        Task {
            do {
                try await onSubmit(value)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                self.error = APIError.from(error).message
                pin = ""
            }
            loading = false
        }
    }
}

// MARK: - Administrar perfiles

struct ManageProfilesView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var editing: ProfileEditTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session.isKids {
                    InlineNotice(message: "Los perfiles se administran desde un perfil de adulto.", icon: "lock.fill", color: Theme.warn)
                }
                ForEach(session.profiles) { profile in
                    Button { editing = ProfileEditTarget(profile: profile) } label: {
                        HStack(spacing: 14) {
                            AvatarView(url: profile.avatarUrl, size: 52, name: profile.name)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(profile.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                                    if profile.locked { Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(Theme.muted) }
                                }
                                Text(detail(profile)).font(.system(size: 13)).foregroundColor(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "pencil").foregroundColor(Theme.text2)
                        }
                        .panel(padding: 12)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(session.isKids)
                }

                if let data = session.profilesData {
                    if data.canCreate && !session.isKids {
                        Button { editing = ProfileEditTarget(profile: nil) } label: {
                            Label("Añadir perfil", systemImage: "plus")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else if let message = data.limitMessage, !message.isEmpty {
                        Text(message).font(.system(size: 13.5)).foregroundColor(Theme.muted)
                    }
                }
            }
            .padding(Theme.gutter)
            .padding(.top, 6)
        }
        .screenBackground()
        .navigationTitle("Perfiles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.loadProfiles() }
        .refreshable { await session.loadProfiles() }
        .sheet(item: $editing) { target in
            ProfileEditorView(profile: target.profile)
        }
    }

    private func detail(_ p: Profile) -> String {
        var parts: [String] = []
        if p.main { parts.append("Principal") }
        if p.kids { parts.append("Infantil") }
        parts.append("Hasta \(p.maxRating)")
        if p.id == session.profile?.id { parts.append("En uso") }
        return parts.joined(separator: " · ")
    }
}

struct ProfileEditTarget: Identifiable {
    let profile: Profile?
    var id: String { profile?.id ?? "new" }
}

struct ProfileEditorView: View {
    let profile: Profile?
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var avatar = "avatar-1"
    @State private var kids = false
    @State private var maxRating = "18+"
    @State private var autoplayNext = true
    @State private var autoplayPreviews = true
    @State private var newPin = ""
    @State private var removePin = false
    @State private var currentPin = ""
    @State private var loading = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var needsSecret: Bool {
        guard let profile else { return false }
        return profile.locked && profile.id != session.profile?.id
    }

    private var ratings: [String] {
        let list = session.config?.ageRatings ?? []
        return list.isEmpty ? ["TP", "7+", "12+", "16+", "18+"] : list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name)
                        .textInputAutocapitalization(.words)
                } header: { Text("Nombre") }

                Section {
                    AvatarPicker(selection: $avatar).padding(.vertical, 6)
                } header: { Text("Avatar") }

                Section {
                    if profile?.main != true {
                        Toggle("Perfil infantil", isOn: $kids)
                    }
                    Picker("Clasificación máxima", selection: $maxRating) {
                        ForEach(ratings, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Reproducir el siguiente episodio", isOn: $autoplayNext)
                    Toggle("Vistas previas automáticas", isOn: $autoplayPreviews)
                } header: { Text("Control parental y reproducción") }

                Section {
                    SecureField("PIN nuevo (4 dígitos)", text: $newPin)
                        .keyboardType(.numberPad)
                        .onChange(of: newPin) { v in
                            let d = String(v.filter(\.isNumber).prefix(4))
                            if d != v { newPin = d }
                        }
                    if profile?.locked == true {
                        Toggle("Quitar el PIN", isOn: $removePin)
                    }
                } header: { Text("PIN") } footer: {
                    Text("El PIN impide que otros entren en este perfil.")
                }

                if needsSecret {
                    Section {
                        SecureField("PIN actual o contraseña de la cuenta", text: $currentPin)
                    } header: { Text("Confirmación") }
                }

                if let error {
                    Section { Text(error).foregroundColor(Theme.bad) }
                }

                if let profile, !profile.main {
                    Section {
                        Button("Eliminar perfil", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg2.ignoresSafeArea())
            .navigationTitle(profile == nil ? "Nuevo perfil" : "Editar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if loading { ProgressView() } else {
                        Button("Guardar", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .confirmationDialog("¿Eliminar este perfil?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Eliminar", role: .destructive, action: delete)
            } message: {
                Text("Se borrarán su lista, su historial y su progreso.")
            }
        }
        .onAppear(perform: fill)
    }

    private func fill() {
        guard let p = profile else { return }
        name = p.name
        avatar = p.avatar
        kids = p.kids
        maxRating = p.maxRating
        autoplayNext = p.autoplayNext
        autoplayPreviews = p.autoplayPreviews
    }

    private func save() {
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "avatar": avatar,
            "kids": kids,
            "max_rating": maxRating,
            "autoplay_next": autoplayNext,
            "autoplay_previews": autoplayPreviews,
        ]
        if removePin { body["remove_pin"] = true } else if newPin.count == 4 { body["new_pin"] = newPin }
        if needsSecret { body["pin"] = currentPin }
        if !newPin.isEmpty && newPin.count != 4 && !removePin {
            error = "El PIN debe tener 4 dígitos."
            return
        }
        loading = true
        error = nil
        Task {
            do {
                _ = try await session.saveProfile(id: profile?.id, body: body)
                Haptics.success()
                dismiss()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            loading = false
        }
    }

    private func delete() {
        guard let profile else { return }
        loading = true
        Task {
            do {
                try await session.deleteProfile(id: profile.id, pin: needsSecret ? currentPin : nil)
                dismiss()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            loading = false
        }
    }
}
