import SwiftUI

// MARK: - Biblioteca sin conexión

struct OfflineLibraryView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerCoordinator
    @ObservedObject private var offline = OfflineDownloadManager.shared

    var body: some View {
        Group {
            if !session.isLoggedIn {
                LoginPrompt(icon: "arrow.down.circle", message: "Inicia sesión con Premium para descargar y ver sin conexión.")
            } else if !(session.subscription?.premium == true) {
                VStack(spacing: 16) {
                    EmptyStateView(
                        icon: "crown",
                        title: "Solo Premium",
                        message: "Ver sin conexión está disponible en los planes Premium. Puedes descargar hasta 5 películas y 5 episodios."
                    )
                    NavigationLink(value: Route.plans) {
                        Text(AppConfig.billingMode == .direct ? "Ver planes" : "Ver mi plan")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 24)
                }
                .frame(maxHeight: .infinity)
            } else if offline.items.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "Sin descargas",
                    message: "En la ficha de una película o episodio toca «Ver sin conexión». El vídeo se guarda solo en la app (no aparece en Fotos)."
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Text("Películas \(offline.movieCount)/\(OfflineDownloadManager.maxMovies) · Episodios \(offline.episodeCount)/\(OfflineDownloadManager.maxEpisodes)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.muted)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(offline.items) { item in
                        OfflineRow(item: item) {
                            play(item)
                        } onRemove: {
                            offline.remove(item.id)
                        } onCancel: {
                            offline.cancel(item.id)
                        } onRetry: {
                            Task {
                                await offline.enqueue(
                                    titleId: item.titleId,
                                    episodeId: item.episodeId,
                                    displayTitle: item.displayTitle,
                                    subtitle: item.subtitle,
                                    poster: item.posterURL.flatMap(URL.init(string:)),
                                    isEpisode: item.isEpisode,
                                    premium: session.subscription?.premium == true,
                                    loggedIn: session.isLoggedIn
                                )
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .screenBackground()
        .navigationTitle("Ver sin conexión")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func play(_ item: OfflineItem) {
        guard let url = item.localFileURL, item.state == .ready else { return }
        player.play(
            titleId: item.titleId,
            episodeId: item.episodeId,
            title: item.displayTitle,
            localFileURL: url,
            isMatroska: item.isMatroska
        )
    }
}

private struct OfflineRow: View {
    let item: OfflineItem
    let onPlay: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let raw = item.posterURL, let url = URL(string: raw) {
                    RemoteImage(url, maxPixel: 280, placeholderIcon: "film")
                } else {
                    Theme.surface2
                    Image(systemName: item.isEpisode ? "play.rectangle" : "film")
                        .foregroundColor(Theme.muted)
                }
            }
            .frame(width: 56, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                statusLabel
                if item.state == .downloading || item.state == .queued {
                    ProgressView(value: max(0.02, item.progress))
                        .tint(Theme.accent2)
                }
            }

            Spacer(minLength: 0)

            if item.state == .ready {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.state == .downloading || item.state == .queued {
                Button("Cancelar", role: .destructive, action: onCancel)
            } else {
                Button("Eliminar", role: .destructive, action: onRemove)
            }
            if item.state == .failed {
                Button("Reintentar", action: onRetry)
            }
        }
        .contextMenu {
            if item.state == .ready { Button("Reproducir", action: onPlay) }
            if item.state == .failed { Button("Reintentar", action: onRetry) }
            if item.state == .downloading || item.state == .queued {
                Button("Cancelar descarga", role: .destructive, action: onCancel)
            } else {
                Button("Eliminar", role: .destructive, action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.state {
        case .ready:
            Label("Listo sin conexión", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.ok)
        case .downloading:
            Text(percentText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.accent2)
        case .queued:
            Text("En cola…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.muted)
        case .failed:
            Text(item.errorMessage ?? "Error al descargar")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.bad)
                .lineLimit(2)
        }
    }

    private var percentText: String {
        let p = Int((item.progress * 100).rounded())
        if item.bytesExpected > 0 {
            return "Descargando \(p)% · \(byteText(item.bytesWritten)) / \(byteText(item.bytesExpected))"
        }
        return "Descargando \(p)%"
    }

    private func byteText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Botón en ficha / episodio

struct OfflineDownloadButton: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var offline = OfflineDownloadManager.shared

    let titleId: String
    var episodeId: String? = nil
    let displayTitle: String
    var subtitle: String? = nil
    var poster: URL? = nil
    var isEpisode = false
    var compact = false

    private var item: OfflineItem? { offline.item(titleId: titleId, episodeId: episodeId) }

    var body: some View {
        Group {
            if compact {
                Button(action: tap) { compactLabel }
                    .buttonStyle(.plain)
            } else {
                Button(action: tap) {
                    Label(labelText, systemImage: iconName)
                }
                .buttonStyle(SecondaryButtonStyle(tint: tint))
            }
        }
        .disabled(item?.state == .downloading || item?.state == .queued)
    }

    private var tint: Color {
        switch item?.state {
        case .ready: return Theme.ok
        case .failed: return Theme.bad
        default: return Theme.text
        }
    }

    private var iconName: String {
        switch item?.state {
        case .ready: return "checkmark.circle.fill"
        case .downloading, .queued: return "arrow.down.circle"
        case .failed: return "exclamationmark.arrow.circlepath"
        case .none: return "arrow.down.circle"
        }
    }

    private var labelText: String {
        switch item?.state {
        case .ready: return "Descargado"
        case .downloading: return "Descargando \(Int((item?.progress ?? 0) * 100))%"
        case .queued: return "En cola…"
        case .failed: return "Reintentar"
        case .none: return "Ver sin conexión"
        }
    }

    @ViewBuilder
    private var compactLabel: some View {
        ZStack {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
            if item?.state == .downloading {
                Circle()
                    .trim(from: 0, to: max(0.05, item?.progress ?? 0))
                    .stroke(Theme.accent2, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(labelText))
    }

    private func tap() {
        guard session.requireLogin() else { return }
        if item?.state == .ready { return }
        if item?.state == .failed {
            offline.remove(item!.id)
        }
        Task {
            await offline.enqueue(
                titleId: titleId,
                episodeId: episodeId,
                displayTitle: displayTitle,
                subtitle: subtitle,
                poster: poster,
                isEpisode: isEpisode,
                premium: session.subscription?.premium == true,
                loggedIn: session.isLoggedIn
            )
        }
    }
}
