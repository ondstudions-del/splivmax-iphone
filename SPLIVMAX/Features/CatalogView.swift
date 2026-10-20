import SwiftUI

@MainActor
final class CatalogModel: ObservableObject {
    @Published private(set) var items: [TitleCard] = []
    @Published private(set) var error: APIError?
    @Published private(set) var loading = false
    @Published private(set) var genres: [GenreCount] = []
    @Published var genre: String
    @Published var sort = "new"
    @Published private(set) var total = 0

    let type: String?
    private var page = 1
    private var pages = 1
    private var generation = 0
    private var loadedVersion = -1

    init(type: String?, genre: String = "") {
        self.type = type
        self.genre = genre
    }

    func loadIfNeeded(version: Int) async {
        if loadedVersion != version || (items.isEmpty && error == nil) {
            loadedVersion = version
            await reload()
        }
        if genres.isEmpty { await loadFilters() }
    }

    func reload() async {
        generation += 1
        page = 1
        pages = 1
        await loadPage(generation: generation, replace: true)
    }

    func loadMore() async {
        guard !loading, page < pages, error == nil else { return }
        page += 1
        await loadPage(generation: generation, replace: false)
    }

    private func loadPage(generation gen: Int, replace: Bool) async {
        let showSpinner = replace && items.isEmpty
        if showSpinner { loading = true }
        do {
            let result: (data: [TitleCard], meta: PageMeta?) = try await APIClient.shared.sendPage(.get, "/catalog", query: [
                "type": type ?? "",
                "genre": genre,
                "sort": sort,
                "page": String(page),
                "per_page": "30",
            ])
            guard gen == generation else { return }
            if replace {
                items = result.data
            } else {
                let known = Set(items.map(\.id))
                items += result.data.filter { !known.contains($0.id) }
            }
            pages = result.meta?.pages ?? 1
            total = result.meta?.total ?? items.count
            error = nil
            ImagePipeline.shared.prefetch(result.data.prefix(18).compactMap(\.tallImage), maxPixel: 360)
        } catch is CancellationError {
        } catch {
            guard gen == generation else { return }
            let e = APIError.from(error)
            if items.isEmpty, !["profile_setup", "profile_required"].contains(e.code) { self.error = e }
            if !replace { page = max(1, page - 1) }
        }
        if gen == generation { loading = false }
    }

    private func loadFilters() async {
        var query: [String: String] = [:]
        if let type, !type.isEmpty { query["type"] = type }
        guard let f: FilterData = try? await APIClient.shared.send(.get, "/filters", query: query) else { return }
        // Chips con títulos reales primero; ocultar géneros vacíos si hay alguno con contenido
        let withCount = f.genres.filter { $0.count > 0 }
        genres = withCount.isEmpty ? f.genres : withCount
    }
}

struct CatalogView: View {
    let type: String?
    let title: String
    let fixedGenre: Bool
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model: CatalogModel

    init(type: String) {
        self.type = type
        self.title = type == "series" ? "Series" : "Películas"
        self.fixedGenre = false
        _model = StateObject(wrappedValue: CatalogModel(type: type))
    }

    init(type: String?, genre: String, title: String) {
        self.type = type
        self.title = title
        self.fixedGenre = true
        _model = StateObject(wrappedValue: CatalogModel(type: type, genre: genre))
    }

    private static let sorts = [
        FilterOption(id: "new", label: "Más recientes"),
        FilterOption(id: "popular", label: "Más vistos"),
        FilterOption(id: "az", label: "A-Z"),
        FilterOption(id: "year", label: "Año"),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                Section {
                    if model.items.isEmpty && model.loading {
                        gridSkeleton
                    } else if model.items.isEmpty, model.error == nil, !model.loading {
                        EmptyStateView(icon: type == "series" ? "tv" : "film", title: "Sin resultados",
                                       message: "No hay títulos con este filtro todavía. Prueba con otro género.")
                    } else {
                        PosterGrid(items: model.items) {
                            Task { await model.loadMore() }
                        }
                        if model.loading && !model.items.isEmpty {
                            ProgressView().tint(Theme.accent2).frame(maxWidth: .infinity).padding()
                        }
                    }
                } header: {
                    if !fixedGenre { genreBar }
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if let error = model.error, model.items.isEmpty {
                ErrorStateView(error: error) { Task { await model.reload() } }
            }
        }
        .refreshable { await model.reload() }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(fixedGenre ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Ordenar", selection: $model.sort) {
                        ForEach(Self.sorts) { Text($0.label).tag($0.id) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                .accessibilityLabel(Text("Ordenar"))
            }
        }
        .onChange(of: model.sort) { _ in Task { await model.reload() } }
        .task(id: session.contentVersion) { await model.loadIfNeeded(version: session.contentVersion) }
    }

    private var genreBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(label: "Todos", selected: model.genre.isEmpty) { select("") }
                ForEach(model.genres) { g in
                    ChipButton(label: g.name, selected: model.genre == g.slug) { select(g.slug) }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
        }
        .background(Theme.bg.opacity(0.96))
    }

    private var gridSkeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 14) {
            ForEach(0..<9, id: \.self) { _ in
                SkeletonBlock().aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .padding(.horizontal, Theme.gutter)
    }

    private func select(_ slug: String) {
        guard model.genre != slug else { return }
        model.genre = slug
        Task { await model.reload() }
    }
}

struct GenreCatalogView: View {
    let slug: String
    let name: String
    let type: String?

    var body: some View {
        CatalogView(type: type, genre: slug, title: name)
    }
}
