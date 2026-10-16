import SwiftUI

// En modo `reader` (App Store) la app no vende ni enlaza a compras: muestra los planes, el plan actual,
// la prueba gratuita (sin coste) y la cancelación. Los pagos manuales solo existen en modo `direct`.

@MainActor
final class PlansModel: ObservableObject {
    @Published var data: PlansData?
    @Published var error: APIError?
    @Published var busy = false

    func load() async {
        do {
            data = try await APIClient.shared.send(.get, "/plans")
            error = nil
        } catch {
            if data == nil { self.error = APIError.from(error) }
        }
    }
}

struct PaymentTarget: Identifiable {
    let id: String
    var preloaded: PaymentDetail? = nil
}

struct PlansView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model = PlansModel()
    @State private var confirmCancel = false
    @State private var paymentTarget: PaymentTarget?

    private var direct: Bool { AppConfig.billingMode == .direct }

    var body: some View {
        Group {
            if let data = model.data {
                content(data)
            } else if let error = model.error {
                ErrorStateView(error: error) { Task { await model.load() } }
            } else {
                LoadingView()
            }
        }
        .screenBackground()
        .navigationTitle("Planes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable {
            await model.load()
            await session.refreshMe()
        }
        .confirmationDialog("¿Cancelar la suscripción?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancelar suscripción", role: .destructive, action: cancelSubscription)
        } message: {
            Text("Conservarás los beneficios hasta el final del periodo pagado.")
        }
        .sheet(item: $paymentTarget) { target in
            PaymentDetailSheet(target: target)
        }
    }

    private func content(_ data: PlansData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.isLoggedIn, !session.isKids {
                    PlanCard()
                }

                if data.trial.enabled, data.trial.eligible, session.isLoggedIn, !session.isKids {
                    trialCard(data.trial)
                }

                Text(direct ? "Elige tu plan" : "Planes de SPLIVMAX")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(Theme.text)
                    .padding(.top, 4)

                ForEach(data.items) { plan in
                    PlanTile(plan: plan, current: isCurrent(plan, data), showPrice: direct, busy: model.busy) {
                        subscribe(plan)
                    }
                }

                if let sub = session.subscription, sub.canCancel, !session.isKids {
                    Button("Cancelar suscripción") { confirmCancel = true }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.bad))
                }

                Text(direct
                     ? "Los pagos se verifican manualmente. Tu plan se activa cuando confirmamos la transferencia."
                     : "Esta app no vende suscripciones. Si ya tienes un plan activo, inicia sesión y disfrútalo aquí.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(Theme.gutter)
            .padding(.bottom, 24)
        }
    }

    private func isCurrent(_ plan: Plan, _ data: PlansData) -> Bool {
        if let current = plan.current { return current }
        if let sub = session.subscription { return sub.plan.id == plan.id }
        return data.currentPlanId == plan.id
    }

    private func trialCard(_ trial: PlansData.Trial) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.premiumGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prueba gratuita de \(trial.days) días")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(Theme.text)
                    if let plan = trial.plan {
                        Text("Disfruta \(plan.name) sin coste.").font(.system(size: 13.5)).foregroundColor(Theme.text2)
                    }
                }
            }
            Button {
                activateTrial()
            } label: {
                if model.busy { ProgressView().tint(.white) } else { Text("Activar prueba gratuita") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy)
        }
        .panel()
    }

    private func activateTrial() {
        model.busy = true
        Task {
            do {
                let r: SubscriptionMessage = try await APIClient.shared.send(.post, "/trial")
                session.setSubscription(r.subscription)
                session.show(r.message ?? "Prueba gratuita activada", .success)
                Haptics.success()
                await session.refreshMe()
                await model.load()
            } catch {
                session.show(APIError.from(error).message, .error)
            }
            model.busy = false
        }
    }

    private func cancelSubscription() {
        model.busy = true
        Task {
            do {
                let r: SubscriptionMessage = try await APIClient.shared.send(.post, "/subscription/cancel")
                session.setSubscription(r.subscription)
                session.show(r.message ?? "Suscripción cancelada", .info)
                await session.refreshMe()
            } catch {
                session.show(APIError.from(error).message, .error)
            }
            model.busy = false
        }
    }

    private func subscribe(_ plan: Plan) {
        guard direct else { return }
        guard session.requireLogin(.register) else { return }
        model.busy = true
        Task {
            do {
                let detail: PaymentDetail = try await APIClient.shared.send(.post, "/plans/\(plan.id)/subscribe")
                paymentTarget = PaymentTarget(id: detail.payment.id, preloaded: detail)
            } catch {
                session.show(APIError.from(error).message, .error)
            }
            model.busy = false
        }
    }
}

private struct PlanTile: View {
    let plan: Plan
    let current: Bool
    let showPrice: Bool
    let busy: Bool
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.name)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(Theme.text)
                if !plan.promoLabel.isEmpty {
                    Text(plan.promoLabel.uppercased())
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(Theme.heroButtonText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.premiumGradient, in: Capsule())
                }
                Spacer()
                if current {
                    Label("Tu plan", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(Theme.ok)
                }
            }

            if showPrice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(plan.isFree ? "Gratis" : plan.priceText)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Theme.gradient)
                    if !plan.isFree { Text(plan.periodText).font(.system(size: 14)).foregroundColor(Theme.text2) }
                }
            }

            if !plan.description.isEmpty {
                Text(plan.description).font(.system(size: 14)).foregroundColor(Theme.text2)
            }

            VStack(alignment: .leading, spacing: 7) {
                feature("sparkles.tv", plan.qualityText)
                feature("rectangle.on.rectangle", plan.maxStreams == 1 ? "1 pantalla a la vez" : "\(plan.maxStreams) pantallas a la vez")
                feature("person.2", plan.maxProfiles == 1 ? "1 perfil" : "Hasta \(plan.maxProfiles) perfiles")
                feature(plan.ads ? "megaphone" : "nosign", plan.ads ? "Con anuncios" : "Sin anuncios")
                if plan.history { feature("clock.arrow.circlepath", "Historial de reproducción") }
                if plan.dailyPlayLimit > 0 { feature("timer", "\(plan.dailyPlayLimit) reproducciones al día") }
                ForEach(plan.benefits, id: \.self) { feature("checkmark", $0) }
            }

            if showPrice && !current && !plan.isFree {
                Button(action: onSubscribe) {
                    if busy { ProgressView().tint(.white) } else { Text("Elegir \(plan.name)") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .stroke(current ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.line), lineWidth: current ? 1.5 : 1)
        )
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.accent2)
                .frame(width: 18)
            Text(text).font(.system(size: 14)).foregroundColor(Theme.text)
        }
    }
}

// MARK: - Pagos (solo modo directo)

@MainActor
final class PaymentsModel: ObservableObject {
    @Published var items: [Payment] = []
    @Published var error: APIError?
    @Published var loading = false
    private var page = 1
    private var pages = 1

    func load(reset: Bool = true) async {
        if loading { return }
        if !reset && page >= pages { return }
        loading = true
        let next = reset ? 1 : page + 1
        do {
            let (list, meta) = try await APIClient.shared.sendPage(.get, "/payments", query: ["page": String(next)], as: [Payment].self)
            items = reset ? list : items + list
            page = meta?.page ?? next
            pages = meta?.pages ?? 1
            error = nil
        } catch {
            if items.isEmpty { self.error = APIError.from(error) }
        }
        loading = false
    }
}

struct PaymentsView: View {
    @StateObject private var model = PaymentsModel()
    @State private var target: PaymentTarget?

    var body: some View {
        Group {
            if let error = model.error {
                ErrorStateView(error: error) { Task { await model.load() } }
            } else if model.items.isEmpty && model.loading {
                LoadingView()
            } else if model.items.isEmpty {
                EmptyStateView(icon: "creditcard", title: "Sin pagos", message: "Aquí verás los pagos de tus planes.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items) { payment in
                        Button { target = PaymentTarget(id: payment.id) } label: { PaymentRow(payment: payment) }
                            .listRowBackground(Theme.surface)
                            .onAppear {
                                if payment.id == model.items.last?.id { Task { await model.load(reset: false) } }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .screenBackground()
        .navigationTitle("Pagos")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.load() } }
        .refreshable { await model.load() }
        .sheet(item: $target, onDismiss: { Task { await model.load() } }) { PaymentDetailSheet(target: $0) }
    }
}

private struct PaymentRow: View {
    let payment: Payment

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(payment.planName).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Text([payment.reference, ISODate.display(payment.createdAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(payment.amountText).font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                PaymentStatusBadge(payment: payment)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PaymentStatusBadge: View {
    let payment: Payment

    var body: some View {
        Text(payment.statusLabel)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundColor(color)
    }

    private var color: Color {
        switch payment.status {
        case "paid", "approved", "completed": return Theme.ok
        case "pending": return payment.proofRef == nil ? Theme.warn : Theme.accent2
        case "rejected", "failed", "cancelled", "expired": return Theme.bad
        default: return Theme.text2
        }
    }
}

struct PaymentDetailSheet: View {
    let target: PaymentTarget
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PaymentDetail?
    @State private var error: APIError?
    @State private var method = ""
    @State private var reference = ""
    @State private var sending = false
    @State private var formError: String?
    @State private var link: WebLink?

    var body: some View {
        NavigationStack {
            Group {
                if let detail {
                    content(detail)
                } else if let error {
                    ErrorStateView(error: error) { Task { await load() } }
                } else {
                    LoadingView()
                }
            }
            .background(Theme.bg2.ignoresSafeArea())
            .navigationTitle("Pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .sheet(item: $link) { SafariView(url: $0.url).ignoresSafeArea() }
        .task {
            if let pre = target.preloaded, detail == nil { apply(pre) } else { await load() }
        }
    }

    private func content(_ d: PaymentDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(d.payment.planName).font(.system(size: 18, weight: .heavy)).foregroundColor(Theme.text)
                        Spacer()
                        PaymentStatusBadge(payment: d.payment)
                    }
                    Text(d.payment.amountText).font(.system(size: 28, weight: .heavy)).foregroundStyle(Theme.gradient)
                    copyRow("Referencia", d.payment.reference)
                }
                .panel()

                if d.payment.status == "pending" {
                    if let proof = d.payment.proofRef, !proof.isEmpty {
                        InlineNotice(message: "Comprobante \(proof) enviado. Activaremos tu plan cuando verifiquemos la transferencia.", icon: "hourglass", color: Theme.accent2)
                    } else {
                        instructions(d)
                    }
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func instructions(_ d: PaymentDetail) -> some View {
        if d.wallet.available, let balance = d.wallet.balance {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saldo disponible: \(Format.money(balance, currency: d.payment.currency))")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Theme.text)
                Button("Pagar con mi saldo", action: payWithWallet)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!d.wallet.enough || sending)
                if !d.wallet.enough {
                    Text("Tu saldo no alcanza para este pago.").font(.system(size: 12.5)).foregroundColor(Theme.muted)
                }
            }
            .panel()
        }

        if let checkout = d.checkout {
            VStack(alignment: .leading, spacing: 10) {
                if let text = checkout.text, !text.isEmpty {
                    Text(text).font(.system(size: 14.5)).foregroundColor(Theme.text2)
                }
                if let raw = checkout.url, let url = URL(string: raw), url.scheme == "https" {
                    Button("Abrir pasarela de pago") { link = WebLink(url: url) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .panel()
        }

        if !d.methods.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transfiere a").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                ForEach(d.methods) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.label).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.accent2)
                        if !m.account.isEmpty { copyRow(m.field.isEmpty ? "Cuenta" : m.field, m.account) }
                        if !m.holder.isEmpty {
                            Text("Titular: \(m.holder)").font(.system(size: 13)).foregroundColor(Theme.text2)
                        }
                    }
                    if m.id != d.methods.last?.id { Divider().overlay(Theme.line) }
                }
                if let qr = d.qr {
                    RemoteImage(qr, maxPixel: 600, contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                }
                if !d.notes.isEmpty {
                    Text(d.notes).font(.system(size: 13)).foregroundColor(Theme.muted)
                }
            }
            .panel()

            VStack(alignment: .leading, spacing: 12) {
                Text("Ya pagué").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                Picker("Medio", selection: $method) {
                    ForEach(d.methods) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                SPXField(label: "Número de referencia o comprobante", text: $reference, icon: "number", submit: .send, onSubmit: sendProof)
                if let formError { InlineError(message: formError) }
                Button(action: sendProof) {
                    if sending { ProgressView().tint(.white) } else { Text("Enviar comprobante") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sending || reference.trimmingCharacters(in: .whitespaces).count < 4 || method.isEmpty)
            }
            .panel()
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundColor(Theme.muted)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundColor(Theme.text).textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = value
                session.show("Copiado", .success)
            } label: {
                Image(systemName: "doc.on.doc").foregroundColor(Theme.accent2)
            }
            .accessibilityLabel(Text("Copiar \(label)"))
        }
    }

    private func apply(_ d: PaymentDetail) {
        detail = d
        if method.isEmpty { method = d.methods.first?.id ?? "" }
    }

    private func load() async {
        do {
            let d: PaymentDetail = try await APIClient.shared.send(.get, "/payments/\(target.id)")
            apply(d)
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
    }

    private func sendProof() {
        guard !sending else { return }
        sending = true
        formError = nil
        Task {
            do {
                let r: PaymentUpdate = try await APIClient.shared.send(.post, "/payments/\(target.id)/proof",
                                                                       body: ["method": method, "reference": reference.trimmingCharacters(in: .whitespaces)])
                session.show(r.message ?? "Comprobante enviado", .success)
                await load()
            } catch {
                formError = APIError.from(error).fullMessage
            }
            sending = false
        }
    }

    private func payWithWallet() {
        sending = true
        Task {
            do {
                let r: PaymentUpdate = try await APIClient.shared.send(.post, "/payments/\(target.id)/wallet")
                if let sub = r.subscription { session.setSubscription(sub) }
                session.show(r.message ?? "Pago completado", .success)
                Haptics.success()
                await session.refreshMe()
                await load()
            } catch {
                session.show(APIError.from(error).message, .error)
            }
            sending = false
        }
    }
}
