import SwiftUI

// Shared memory-only catalogs: one search across Movies and Live TV.
struct TVSearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: SessionCatalog
    @State private var query = ""
    @State private var filter = "all"
    @State private var results: [SearchHit] = []
    @State private var notices: [String] = []
    @State private var playing: CatalogItem?
    @State private var limit = 60
    @State private var retry = 0
    private var hasQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                StreamHeading(title: "Search", subtitle: "Movies and live channels. Every category. One place.")
                HStack(spacing: 30) {
                    TextField("Search movies and Live TV", text: $query).frame(maxWidth: 850)
                    Picker("Search in", selection: $filter) {
                        Text("All").tag("all")
                        Text("Movies").tag(LibraryKind.movies.rawValue)
                        Text("Live TV").tag(LibraryKind.live.rawValue)
                    }.pickerStyle(.segmented).frame(maxWidth: 580)
                }
                if !hasQuery {
                    Label("Enter at least two characters to explore your library", systemImage: "sparkle.magnifyingglass")
                        .foregroundStyle(.secondary).padding(36).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                } else {
                    ForEach(LibraryKind.allCases) { kind in
                        if let progress = catalog.progress[kind] { ProgressView("\(kind.title): \(progress)") }
                    }
                    ForEach(notices, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    if !notices.isEmpty { Button("Retry unavailable catalogs") { retry += 1 } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 36) {
                        ForEach(Array(results.prefix(limit))) { hit in
                            Button { playing = hit.item } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    TVCatalogCard(item: hit.item)
                                    Label(hit.item.kind.title, systemImage: hit.item.kind.symbol)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.card).contextMenu {
                                Button(TVFavorites.contains(item: hit.item, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggle(item: hit.item, model: model) }
                            }
                        }
                    }.padding(.vertical, 20)
                    if results.count > limit { Button("More results") { limit += 60 } }
                    if catalog.progress.isEmpty && results.isEmpty {
                        Text("No matching titles in the loaded catalogs.").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 64).padding(.vertical, 40)
        }
        .background { StreamBackdrop() }
        .task(id: "\(hasQuery)-\(model.libraryRevision)-\(retry)") {
            guard hasQuery, model.signedIn, model.providerReady else { return }
            notices = []
            async let movies: Void = load(.movies)
            async let live: Void = load(.live)
            _ = await (movies, live)
        }
        .task(id: "\(query)-\(filter)-\(catalog.revision)-\(model.libraryRevision)") {
            limit = 60
            guard hasQuery else { results = []; return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let snapshot = LibraryKind.allCases.flatMap { catalog.searchable[$0] ?? [] }.filter(model.preferences.visible)
            let term = query; let choice = filter
            let worker = Task.detached(priority: .userInitiated) { UnifiedSearch.matches(snapshot, query: term, filter: choice) }
            let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }; results = found
        }
        .fullScreenCover(item: $playing) {
            CatalogDestination(item: $0, channels: catalog.searchable[.live] ?? [])
        }
    }
    private func load(_ kind: LibraryKind) async {
        do {
            let result = try await catalog.loadAll(kind: kind, model: model)
            if !Task.isCancelled && !result.notice.isEmpty { notices.append("\(kind.title): \(result.notice)") }
        } catch { if !Task.isCancelled { notices.append("\(kind.title): \(error.localizedDescription)") } }
    }
}
