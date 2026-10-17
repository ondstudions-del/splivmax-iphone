import SwiftUI

@MainActor
final class TitleDetailModel: ObservableObject {
    @Published private(set) var detail: TitleDetail?
    @Published private(set) var error: APIError?
    @Published var seasonId: String?
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentsTotal = 0
    @Published private(set) var commentsLoading = false
    private var commentsPage = 1
    private var commentsPages = 1

    let id: String

    init(id: String) { self.id = id }

    func load() async {
        do {
            let d: TitleDetail = try await APIClient.shared.send(.get, "/titles/\(id)")
            detail = d
            error = nil
            if seasonId == nil || !d.seasonList.contains(where: { $0.id == seasonId }) {
                let resumeSeason = d.resume.flatMap { r in d.seasonList.first { $0.episodes.contains { $0.id == r.episodeId } } }
                seasonId = resumeSeason?.id ?? d.seasonList.first?.id
            }
            if (d.commentsEnabled || !d.card.isSeries) && comments.isEmpty {
                await loadComments(reset: true)
            }
        } catch is CancellationError {
        } catch {
            let e = APIError.from(error)
            if !["profile_setup", "profile_required"].contains(e.code) { self.error = e }
        }
    }

    var season: Season? {
        detail?.seasonList.first { $0.id == seasonId } ?? detail?.seasonList.first
    }

    func loadComments(reset: Bool) async {
        guard !commentsLoading else { return }
        if reset { commentsPage = 1 } else {
            guard commentsPage < commentsPages else { return }
            commentsPage += 1
        }
        commentsLoading = true
        defer { commentsLoading = false }
        guard let r: (data: [Comment], meta: PageMeta?) = try? await APIClient.shared.sendPage(.get, "/titles/\(id)/comments", query: ["page": String(commentsPage)]) else { return }
        comments = reset ? r.data : comments + r.data.filter { c in !comments.contains { $0.id == c.id } }
        commentsPages = r.meta?.pages ?? 1
        commentsTotal = r.meta?.total ?? comments.count
    }

    func post(comment body: String) async throws {
        let c: Comment = try await APIClient.shared.send(.post, "/titles/\(id)/comments", body: ["body": body])
        comments.insert(c, at: 0)
        commentsTotal += 1
    }

    func delete(_ comment: Comment) async throws {
        let _: [String: Bool] = try await APIClient.shared.send(.post, "/titles/\(id)/comments/\(comment.id)/delete")
        comments.removeAll { $0.id == comment.id }
        commentsTotal = max(0, commentsTotal - 1)
    }
}

struct TitleDetailView: View {
    let id: String
    let preview: TitleCard?

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @StateObject private var model: TitleDetailModel
    @State private var showFullSynopsis = false
    @State private var reporting = false
    @State private var scrollToComments = false

    init(id: String, preview: TitleCard?) {
        self.id = id
        self.preview = preview
        _model = StateObject(wrappedValue: TitleDetailModel(id: id))
    }

    private var card: TitleCard? { model.detail?.card ?? preview }

    private var shareURL: URL {
        AppConfig.webURL.appendingPathComponent("titulo/\(id)")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop
                    if let card {
                        VStack(alignment: .leading, spacing: 18) {
                            header(card)
                            if let detail = model.detail {
                                actions(card, detail)
                                accessNotice(card, detail)
                                synopsis(detail)
                                if !detail.seasonList.isEmpty { seasons(detail) }
                                info(card, detail)
                            } else if let error = model.error {
                                ErrorStateView(error: error) { Task { await model.load() } }
                                    .frame(minHeight: 240)
                            } else {
                                ProgressView().tint(Theme.accent2).frame(maxWidth: .infinity).padding(.vertical, 30)
                            }
                        }
                        .padding(.horizontal, Theme.gutter + 4)
                        .padding(.top, -38)
                    }

                    if let detail = model.detail {
                        if !detail.similar.isEmpty {
                            TitleRow(title: "Títulos similares", items: detail.similar)
                                .padding(.top, 28)
                        }
                        if detail.commentsEnabled || !detail.card.isSeries {
                            CommentsSection(model: model)
                                .id("comments")
                                .padding(.horizontal, Theme.gutter + 4)
                                .padding(.top, 28)
                        }
                        if !detail.rightsHolder.isEmpty {
                            Text("© \(detail.rightsHolder)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.muted)
                                .padding(.horizontal, Theme.gutter + 4)
                                .padding(.top, 24)
                        }
                    } else if card == nil, let error = model.error {
                        ErrorStateView(error: error) { Task { await model.load() } }
                            .frame(minHeight: 400)
                    }
                }
                .padding(.bottom, 32)
            }
            .onChange(of: scrollToComments) { go in
                guard go else { return }
                withAnimation(.easeInOut) { proxy.scrollTo("comments", anchor: .top) }
                scrollToComments = false
            }
        }
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let card {
                    ShareLink(item: shareURL,
                              subject: Text(card.title),
                              message: Text("Mira «\(card.title)» en SPLIVMAX")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel(Text("Compartir"))
                }
            }
        }
        .task(id: session.contentVersion) { await model.load() }
        .onChange(of: player.closedCount) { _ in Task { await model.load() } }
        .sheet(isPresented: $reporting) {
            ReportSheet(titleId: id, episodeId: nil)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Cabecera

    private var backdrop: some View {
        let width = Layout.screenWidth
        return ZStack {
            RemoteImage(card?.wideImage, maxPixel: 1200)
            Theme.detailShade
            LinearGradient(colors: [Color(hex: 0x04060C, alpha: 0.7), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
        }
        .frame(width: width, height: (width * 9 / 16).rounded() + 60)
        .clipped()
        .accessibilityHidden(true)
    }

    private func header(_ card: TitleCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title)
                .font(.system(size: 28, weight: .black))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let original = model.detail?.originalTitle, !original.isEmpty, original != card.title {
                Text(original).font(.system(size: 14)).foregroundColor(Theme.muted)
            }
            MetaLine(card: card)
            if !card.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(card.genres) { g in
                            NavigationLink(value: Route.genre(slug: g.slug, name: g.name, type: nil)) {
                                Text(g.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(Theme.text2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surface2, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Acciones

    private func actions(_ card: TitleCard, _ detail: TitleDetail) -> some View {
        let favorite = session.isFavorite(card.id, fallback: detail.favorite)
        return VStack(spacing: 8) {
            if card.isUpcoming {
                VStack(spacing: 6) {
                    Label(card.releaseText ?? "Próximamente", systemImage: "calendar")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.accent2)
                    if let date = ISODate.parse(card.releaseAt) {
                        CountdownText(target: date)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
            } else {
                Button { play(card, detail) } label: {
                    Label(playLabel(card, detail), systemImage: "play.fill")
                }
                .buttonStyle(WhiteButtonStyle())
                .disabled(!card.playable)

                if let p = detail.progress, !p.completed, p.position > 10, p.duration > 0 {
                    HStack(spacing: 10) {
                        ProgressBar(value: Double(p.percent) / 100)
                        Text("Faltan \(Format.duration(minutes: max(1, (p.duration - p.position) / 60)) ?? "")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.muted)
                            .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
            }

            if !card.isSeries, !card.isUpcoming, card.playable {
                OfflineDownloadButton(
                    titleId: card.id,
                    displayTitle: card.title,
                    poster: card.tallImage ?? card.wideImage,
                    isEpisode: false
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await session.toggleFavorite(card.id, current: favorite) }
                } label: {
                    Label(favorite ? "En Mi lista" : "Mi lista", systemImage: favorite ? "checkmark" : "plus")
                }
                .buttonStyle(SecondaryButtonStyle(tint: favorite ? Theme.accent2 : Theme.text))

                ShareLink(
                    item: shareURL,
                    subject: Text(card.title),
                    message: Text("Mira «\(card.title)» en SPLIVMAX")
                ) {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            HStack(spacing: 8) {
                if detail.commentsEnabled || !card.isSeries {
                    Button { scrollToComments = true } label: {
                        Label(
                            detail.commentsCount > 0 ? "Comentar (\(detail.commentsCount))" : "Comentar",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    if session.requireLogin() { reporting = true }
                } label: {
                    Label("Reportar", systemImage: "flag")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func playLabel(_ card: TitleCard, _ detail: TitleDetail) -> String {
        if card.isSeries {
            return detail.resume?.label ?? "Reproducir"
        }
        if let p = detail.progress, !p.completed, p.position > 10 { return "Continuar" }
        return "Reproducir"
    }

    private func play(_ card: TitleCard, _ detail: TitleDetail) {
        guard session.requireLogin() else { return }
        let episodeId = card.isSeries ? detail.resume?.episodeId : nil
        if let offline = OfflineDownloadManager.shared.item(titleId: card.id, episodeId: episodeId),
           offline.state == .ready, let url = offline.localFileURL {
            player.play(titleId: card.id, episodeId: episodeId, title: card.title,
                        localFileURL: url, isMatroska: offline.isMatroska)
            return
        }
        player.play(titleId: card.id, episodeId: episodeId, title: card.title)
    }

    @ViewBuilder
    private func accessNotice(_ card: TitleCard, _ detail: TitleDetail) -> some View {
        if session.isLoggedIn && !detail.canWatch && !card.isUpcoming && card.isPremium {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PremiumBadge()
                    Text("Contenido Premium").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                }
                Text(session.subscription?.trial.ended == true
                     ? "Tu prueba gratuita terminó. Este título requiere un plan Premium activo en tu cuenta SPLIVMAX."
                     : "Este título requiere un plan Premium activo en tu cuenta SPLIVMAX.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text2)
                NavigationLink(value: Route.plans) {
                    Text(AppConfig.billingMode == .direct ? "Ver planes" : "Ver mi plan")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .panel()
        }
    }

    private func synopsis(_ detail: TitleDetail) -> some View {
        let text = detail.synopsisFull.isEmpty ? (detail.card.synopsis ?? "") : detail.synopsisFull
        return VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(Theme.text2)
                .lineSpacing(3)
                .lineLimit(showFullSynopsis ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 220 {
                Button(showFullSynopsis ? "Ver menos" : "Ver más") {
                    withAnimation(.easeInOut) { showFullSynopsis.toggle() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accent2)
            }
        }
    }

    // MARK: Temporadas

    private func seasons(_ detail: TitleDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodios").font(.system(size: 19, weight: .bold)).foregroundColor(Theme.text)
                Spacer()
                if detail.seasonList.count > 1 {
                    Menu {
                        Picker("Temporada", selection: Binding(get: { model.seasonId ?? "" }, set: { model.seasonId = $0 })) {
                            ForEach(detail.seasonList) { s in
                                Text(s.title).tag(s.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.season?.title ?? "Temporada")
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface2, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    }
                } else if let s = detail.seasonList.first {
                    Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.muted)
                }
            }

            if let season = model.season {
                LazyVStack(spacing: 4) {
                    ForEach(season.episodes) { ep in
                        EpisodeRow(
                            episode: ep,
                            current: ep.id == detail.resume?.episodeId,
                            titleId: detail.card.id,
                            seriesTitle: detail.card.title,
                            poster: detail.card.tallImage ?? detail.card.wideImage
                        ) {
                            guard session.requireLogin() else { return }
                            if let offline = OfflineDownloadManager.shared.item(titleId: detail.card.id, episodeId: ep.id),
                               offline.state == .ready, let url = offline.localFileURL {
                                player.play(titleId: detail.card.id, episodeId: ep.id, title: detail.card.title,
                                            localFileURL: url, isMatroska: offline.isMatroska)
                            } else {
                                player.play(titleId: detail.card.id, episodeId: ep.id, title: detail.card.title)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Información

    @ViewBuilder
    private func info(_ card: TitleCard, _ detail: TitleDetail) -> some View {
        let author = detail.authors.joined(separator: ", ")
        let castText = detail.cast.prefix(12).map {
            $0.character.isEmpty ? $0.name : "\($0.name) (\($0.character))"
        }.joined(separator: ", ")
        let rows: [(String, String)] = [
            ("Autor", author),
            ("Duración", card.durationText ?? ""),
            ("Reparto", castText),
            ("Idiomas", detail.languages.map(\.name).joined(separator: ", ")),
            ("Subtítulos", detail.subtitleLanguages.map(\.name).joined(separator: ", ")),
        ].filter { !$0.1.isEmpty }

        VStack(alignment: .leading, spacing: 14) {
            Text("Información")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Theme.text)

            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.0)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundColor(Theme.muted)
                            Text(row.1)
                                .font(.system(size: 14.5))
                                .foregroundColor(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !detail.tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Etiquetas")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(Theme.muted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(detail.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(Theme.text2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surface2, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EpisodeRow: View {
    let episode: Episode
    var current = false
    var titleId: String = ""
    var seriesTitle: String = ""
    var poster: URL? = nil
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onPlay) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RemoteImage(episode.thumbnail, maxPixel: 400, placeholderIcon: "play.rectangle")
                        if episode.playable {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        if let p = episode.progress, p.percent > 0 {
                            VStack { Spacer(); ProgressBar(value: Double(p.percent) / 100, height: 3).padding(5) }
                        }
                    }
                    .frame(width: 130, height: 73)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).stroke(current ? Theme.accent2 : Color.white.opacity(0.06), lineWidth: current ? 1.5 : 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(episode.number ?? 0). \(episode.title)")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            if let d = Format.duration(minutes: episode.durationMin) { Text(d) }
                            if let p = episode.progress, p.completed {
                                Label("Visto", systemImage: "checkmark.circle.fill").foregroundColor(Theme.ok)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        if let release = ISODate.display(episode.releaseAt) {
                            Text("Se estrena el \(release)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.accent2)
                        } else if !episode.synopsis.isEmpty {
                            Text(episode.synopsis)
                                .font(.system(size: 12.5))
                                .foregroundColor(Theme.text2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!episode.playable)
            .opacity(episode.playable || episode.releaseAt != nil ? 1 : 0.55)

            if episode.playable, !titleId.isEmpty {
                OfflineDownloadButton(
                    titleId: titleId,
                    episodeId: episode.id,
                    displayTitle: seriesTitle,
                    subtitle: "E\(episode.number ?? 0). \(episode.title)",
                    poster: episode.thumbnail ?? poster,
                    isEpisode: true,
                    compact: true
                )
                .padding(.top, 20)
            }
        }
        .accessibilityLabel(Text("Episodio \(episode.number ?? 0), \(episode.title)"))
    }
}

/// Cuenta regresiva hasta el estreno (como data-countdown de la web).
struct CountdownText: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(target.timeIntervalSince(context.date)))
            let d = left / 86_400, h = (left % 86_400) / 3600, m = (left % 3600) / 60, s = left % 60
            Text(d > 0 ? "\(d) d \(h) h \(m) min" : String(format: "%02d:%02d:%02d", h, m, s))
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
        }
    }
}

// MARK: - Comentarios

private struct CommentsSection: View {
    @ObservedObject var model: TitleDetailModel
    @EnvironmentObject private var session: SessionStore
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var deleting: Comment?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.commentsTotal > 0 ? "Comentarios (\(model.commentsTotal))" : "Comentarios")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Theme.text)

            if session.isLoggedIn {
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("Escribe un comentario…", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(12)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
                        .foregroundColor(Theme.text)
                    if let error { InlineError(message: error) }
                    Button(action: send) {
                        if sending { ProgressView().tint(.white) } else { Text("Publicar") }
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || sending)
                }
            } else {
                Button("Inicia sesión para comentar") { _ = session.requireLogin() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            if model.comments.isEmpty && !model.commentsLoading {
                Text("Sé el primero en comentar.").font(.system(size: 14)).foregroundColor(Theme.muted)
            }

            ForEach(model.comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    AvatarView(url: c.avatarUrl, size: 34, name: c.author)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.author).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.text)
                            if let when = ISODate.relative(c.createdAt) {
                                Text(when).font(.system(size: 12)).foregroundColor(Theme.muted)
                            }
                            Spacer()
                            if c.canDelete {
                                Button { deleting = c } label: {
                                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(Theme.muted)
                                }
                                .accessibilityLabel(Text("Borrar comentario"))
                            }
                        }
                        Text(c.body)
                            .font(.system(size: 14.5))
                            .foregroundColor(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .onAppear {
                    if c.id == model.comments.last?.id { Task { await model.loadComments(reset: false) } }
                }
            }
        }
        .confirmationDialog("¿Borrar este comentario?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                guard let c = deleting else { return }
                Task {
                    do { try await model.delete(c) } catch { session.show(APIError.from(error).message, .error) }
                }
            }
        }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        error = nil
        Task {
            do {
                try await model.post(comment: body)
                text = ""
                Haptics.success()
            } catch {
                self.error = APIError.from(error).message
            }
            sending = false
        }
    }
}

// MARK: - Reportar

struct ReportSheet: View {
    let titleId: String
    let episodeId: String?
    var source = "title"

    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var details = ""
    @State private var sending = false
    @State private var error: String?
    @State private var done: String?

    private var reasons: [ServerConfig.Reason] {
        let list = session.config?.reportReasons ?? []
        return list.isEmpty ? [
            ServerConfig.Reason(id: "no_play", label: "No se reproduce"),
            ServerConfig.Reason(id: "audio", label: "Problemas de audio"),
            ServerConfig.Reason(id: "subtitles", label: "Subtítulos incorrectos"),
            ServerConfig.Reason(id: "other", label: "Otro"),
        ] : list
    }

    var body: some View {
        NavigationStack {
            Form {
                if let done {
                    Section { Label(done, systemImage: "checkmark.circle.fill").foregroundColor(Theme.ok) }
                } else {
                    Section {
                        Picker("Motivo", selection: $reason) {
                            Text("Elige un motivo").tag("")
                            ForEach(reasons) { Text($0.label).tag($0.id) }
                        }
                    } header: { Text("¿Qué ocurre?") }
                    Section {
                        TextField("Cuéntanos más (opcional)", text: $details, axis: .vertical)
                            .lineLimit(3...6)
                    } header: { Text("Detalles") }
                    if let error { Section { Text(error).foregroundColor(Theme.bad) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg2.ignoresSafeArea())
            .navigationTitle("Reportar un problema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "Cancelar" : "Cerrar") { dismiss() } }
                if done == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if sending { ProgressView() } else { Button("Enviar", action: send).disabled(reason.isEmpty) }
                    }
                }
            }
        }
    }

    private func send() {
        sending = true
        error = nil
        var body: [String: Any] = ["reason": reason, "details": details, "source": source]
        if let episodeId { body["episode_id"] = episodeId }
        Task {
            do {
                let r: MessageResponse = try await APIClient.shared.send(.post, "/titles/\(titleId)/report", body: body)
                done = r.message ?? "Gracias, recibimos tu reporte."
                Haptics.success()
            } catch {
                self.error = APIError.from(error).fullMessage
            }
            sending = false
        }
    }
}
