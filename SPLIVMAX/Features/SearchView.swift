import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [TitleCard] = []
    @Published private(set) var total = 0
    @Published private(set) var searching = false
    @Published private(set) var error: APIError?
    @Published private(set) var searchedQuery = ""
    @Published private(set) var genres: [GenreCount] = []
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: Prefs.recentSearchesKey) ?? []

    /// Búsqueda instantánea: espera 300 ms sin escribir antes de consultar.
    func run(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            total = 0
            searchedQuery = ""
            error = nil
            searching = false
            return
        }
        searching = true
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let r: (data: [TitleCard], meta: PageMeta?) = try await APIClient.shared.sendPage(.get, "/search", query: ["q": q, "limit": "50"])
            results = r.data
            total = r.meta?.total ?? r.data.count
            searchedQuery = q
            error = nil
            searching = false
        } catch is CancellationError {
        } catch {
            self.error = APIError.from(error)
            searching = false
        }
    }

    func loadGenres() async {
        guard genres.isEmpty else { return }
        // Preferir géneros con conteo real; filtrar vacíos al final
        if let r: ItemsList<GenreCount> = try? await APIClient.shared.send(.get, "/genres") {
            let withCount = r.items.filter { $0.count > 0 }
            genres = withCount.isEmpty ? r.items : withCount
            return
        }
        if let f: FilterData = try? await APIClient.shared.send(.get, "/filters") {
            let withCount = f.genres.filter { $0.count > 0 }
            genres = withCount.isEmpty ? f.genres : withCount
        }
    }

    func remember(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        recent = Array(([q] + recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(8))
        UserDefaults.standard.set(recent, forKey: Prefs.recentSearchesKey)
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Prefs.recentSearchesKey)
    }
}

struct SearchView: View {
    @StateObject private var model = SearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    suggestions
                } else if let error = model.error, model.results.isEmpty {
                    ErrorStateView(error: error) { Task { await model.run(model.query) } }
                        .frame(minHeight: 320)
                } else if model.results.isEmpty && !model.searching && !model.searchedQuery.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Sin resultados para «\(model.searchedQuery)»",
                                   message: "Prueba con otro título, género o palabras de la descripción.")
                        .padding(.top, 40)
                } else {
                    if !model.searchedQuery.isEmpty {
                        Text(model.total == 1 ? "1 resultado" : "\(model.total) resultados")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Theme.muted)
                            .padding(.horizontal, Theme.gutter)
                    }
                    PosterGrid(items: model.results)
                        .simultaneousGesture(TapGesture().onEnded { model.remember(model.query) })
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.query) { await model.run(model.query) }
        .task { await model.loadGenres() }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Buscar")
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(Theme.text)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                TextField("Título, género o descripción…", text: $model.query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundColor(Theme.text)
                    .onSubmit { model.remember(model.query) }
                if model.searching {
                    ProgressView().tint(Theme.accent2).scaleEffect(0.8)
                } else if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted)
                    }
                    .accessibilityLabel(Text("Borrar búsqueda"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(focused ? Theme.accent.opacity(0.8) : Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.bg.opacity(0.97).ignoresSafeArea(edges: .top))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Búsquedas recientes").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.text)
                        Spacer()
                        Button("Borrar") { model.clearRecent() }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Theme.accent2)
                    }
                    ForEach(model.recent, id: \.self) { q in
                        Button { model.query = q } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").foregroundColor(Theme.muted)
                                Text(q).foregroundColor(Theme.text2)
                                Spacer()
                                Image(systemName: "arrow.up.left").font(.system(size: 12)).foregroundColor(Theme.muted)
                            }
                            .font(.system(size: 15))
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }

            if !model.genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Explorar por género").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.text)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(model.genres) { g in
                            NavigationLink(value: Route.genre(slug: g.slug, name: g.name, type: nil)) {
                                HStack {
                                    Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                                    Spacer()
                                    Text("\(g.count)").font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 54)
                                .background(
                                    LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.surface2], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }
}
