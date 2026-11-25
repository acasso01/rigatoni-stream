import SwiftUI

// Load category shelves on demand rather than downloading the entire movie catalog.
struct TVMoviesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var categories: [CatalogCategory] = []
    @State private var featured: CatalogItem?
    @State private var count = 4
    @State private var loading = false
    @State private var error = ""
    @State private var retry = 0
    @State private var searchQuery = ""
    @State private var searchResults: [CatalogItem] = []
    @State private var searchError = ""
    @State private var searchLoading = false
    // Movie detail is pushed on the NavigationStack (not a fullScreenCover)
    // so the player's own fullScreenCover presents from a stack view — a
    // single modal level, which tvOS handles reliably. Nested covers
    // (cover presenting a cover) silently fail on tvOS: Play never started.
    @State private var detailItem: CatalogItem?
    @State private var showingDetail = false

    private var searchTerm: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchingCatalog: Bool { searchTerm.count >= 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    StreamHeading(title: "Movies", subtitle: "Make tonight a movie night.")
                    TextField("Search all movies", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityLabel("Search all movies")
                    if !searchTerm.isEmpty && !searchingCatalog {
                        Text("Enter at least two characters to search all enabled movie categories.")
                            .foregroundStyle(TVTheme.muted)
                    }
                    if searchingCatalog {
                        if searchLoading {
                            ProgressView(catalog.progress[.movies] ?? "Searching all enabled movie categories…")
                        }
                        if !searchError.isEmpty { Text(searchError).foregroundStyle(TVTheme.muted) }
                        if searchResults.isEmpty && !searchLoading {
                            Text(searchError.isEmpty ? "No matching movies." : "No results are available yet.")
                                .foregroundStyle(TVTheme.muted)
                        } else if !searchResults.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 22)], spacing: 30) {
                                ForEach(Array(searchResults.prefix(count)), id: \.scopedID) { item in
                                    Button { openDetail(item) } label: { TVCatalogCard(item: item) }
                                        .buttonStyle(TVCardButtonStyle())
                                }
                            }
                            if searchResults.count > count {
                                Button("Show more") { count += 60 }.buttonStyle(.bordered)
                            }
                            Text("\(searchResults.count) matching movies").font(.caption).foregroundStyle(TVTheme.muted)
                        }
                    } else {
                    if !categories.isEmpty { categoryStrip(landing: featured == nil) }
                    if let featured {
                        TVEntryControl(section: .movies) {
                            TVHeroBanner(title: featured.name, subtitle: "Movie details, overview and Continue/Restart", badge: "FEATURED MOVIE", poster: featured.poster, posterKind: .movies) { openDetail(featured) }
                        }
                    }
                    else if loading { ProgressView("Loading movies…").padding(40).tvLanding(for: .movies, when: categories.isEmpty) }
                    if !model.providerReady {
                        Text("Save your provider in Settings to browse movies.").foregroundStyle(.secondary)
                            .tvLanding(for: .movies, when: featured == nil && !loading && categories.isEmpty)
                    }
                    if !error.isEmpty {
                        HStack {
                            Text(error)
                            if model.providerReady && featured == nil && categories.isEmpty && !loading {
                                TVEntryControl(section: .movies) { Button("Retry") { retry += 1 } }
                            } else {
                                Button("Retry") { retry += 1 }
                            }
                        }.foregroundStyle(.secondary)
                    }
                    ForEach(Array(categories.prefix(count))) { category in
                        TVMovieShelf(category: category) { openDetail($0) }
                    }
                    if count < categories.count {
                        Button("More categories") { count += 4 }.buttonStyle(.bordered)
                    }
                    }
                }.padding(.horizontal, 30).padding(.vertical, 20)
            }
            .background { StreamBackdrop() }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                categories = []; featured = nil; count = 4; error = ""
                guard model.providerReady else { return }
                loading = true; defer { loading = false }
                do {
                    let loaded = try await catalog.categories(kind: .movies, model: model)
                    try Task.checkCancellation(); categories = model.preferences.browseCategories(loaded, section: .movies)
                    if let first = categories.first {
                        let items = try await catalog.items(kind: .movies, category: first.id, model: model)
                        try Task.checkCancellation(); featured = items.first { $0.poster != nil } ?? items.first
                    }
                    if loaded.isEmpty { error = "No movie categories are available." }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .task(id: "movie-search-\(model.libraryRevision)-\(searchTerm)") {
                guard searchingCatalog else { searchResults = []; searchError = ""; searchLoading = false; return }
                let term = searchTerm
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled else { return }
                searchResults = []
                searchLoading = true
                searchError = ""
                count = 60
                defer { if !Task.isCancelled { searchLoading = false } }
                do {
                    let result = try await catalog.loadAll(kind: .movies, model: model)
                    guard !Task.isCancelled, term == searchTerm else { return }
                    let categories = catalog.knownCategories(kind: .movies)
                    let enabled = result.items.filter { model.preferences.accepts($0, categories: categories) }
                    let worker = Task.detached(priority: .userInitiated) { CatalogIndex.matches(enabled, query: term) }
                    let matches = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, term == searchTerm else { return }
                    searchResults = MovieTitle.unique(matches)
                    searchError = result.notice
                } catch {
                    if !Task.isCancelled { searchError = error.localizedDescription }
                }
            }
            .task(id: "movie-search-progress-\(model.libraryRevision)-\(catalog.revision)-\(searchTerm)") {
                guard searchingCatalog else { return }
                let term = searchTerm
                let partial = (catalog.searchable[.movies] ?? []).filter {
                    model.preferences.accepts($0, categories: catalog.knownCategories(kind: .movies))
                }
                guard !partial.isEmpty else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    CatalogIndex.matches(partial, query: term)
                }
                let matches = await withTaskCancellationHandler(
                    operation: { await worker.value },
                    onCancel: { worker.cancel() }
                )
                guard !Task.isCancelled, term == searchTerm else { return }
                searchResults = MovieTitle.unique(matches)
            }
            .navigationDestination(isPresented: $showingDetail) {
                if let item = detailItem { MovieDetailView(item: item) }
            }
        }
    }

    private func openDetail(_ item: CatalogItem) {
        detailItem = item
        showingDetail = true
    }

    private func categoryStrip(landing: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                let allTitles = NavigationLink("All titles") { TVCatalogBrowser(kind: .movies, allowPins: false, initialCategoryID: "all") }.buttonStyle(.bordered)
                if landing { TVEntryControl(section: .movies) { allTitles } } else { allTitles }
                ForEach(categories) { category in
                    NavigationLink { TVCatalogBrowser(kind: .movies, allowPins: false, initialCategoryID: category.id) } label: {
                        Text(category.name)
                            .font(.system(size: 18, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 150, maxWidth: 280, minHeight: 58)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }.buttonStyle(.bordered)
                }
            }.padding(.vertical, 12)
        }
    }

    private func hero(_ item: CatalogItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            ProviderPoster(url: item.poster, kind: .movies)
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 18) {
                Text("IN THE SPOTLIGHT").font(.caption.weight(.semibold)).tracking(4)
                Text(model.preferences.itemTitle(item)).font(.system(size: 48, weight: .bold)).lineLimit(2)
                Button { openDetail(item) } label: { Label("Watch movie", systemImage: "play.fill").padding(.horizontal, 22) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            }.padding(40)
        }.frame(height: 490).clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

private struct TVMovieShelf: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    let category: CatalogCategory
    let play: (CatalogItem) -> Void
    @State private var items: [CatalogItem] = []
    @State private var loading = true
    @State private var error = ""
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(category.name).font(.title2.bold()).lineLimit(1)
                Spacer()
                NavigationLink { TVCatalogBrowser(kind: .movies, allowPins: false, initialCategoryID: category.id) } label: {
                    Label("See all", systemImage: "chevron.right").font(.callout)
                }.buttonStyle(.bordered)
            }
            if loading { ProgressView().padding(24) }
            else if !error.isEmpty {
                HStack { Text(error).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(items, id: \.scopedID) { item in
                        Button { play(item) } label: { TVCatalogCard(item: item) }.buttonStyle(TVCardButtonStyle()).contextMenu {
                            Button(TVFavorites.contains(item: item, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggle(item: item, model: model) }
                        }
                    }
                }.padding(.vertical, 20).padding(.horizontal, 12)
            }
        }
        .task(id: "\(category.id)-\(model.libraryRevision)-\(retry)") {
            loading = true; error = ""; items = []
            defer { loading = false }
            do {
                let loaded = try await catalog.items(kind: .movies, category: category.id, model: model)
                try Task.checkCancellation(); items = Array(loaded.filter(model.preferences.visible).prefix(20))
                if items.isEmpty { error = "No movies in this category." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
