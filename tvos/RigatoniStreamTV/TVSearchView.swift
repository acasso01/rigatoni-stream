import SwiftUI

// Search tab: kind selector (Live TV / Movies), search field, results grid.
// Uses the same full-catalog fast path + category fallback as the iPhone
// build (shared CatalogLoader), with the same 200 ms debounce and
// off-main-thread filtering.
struct TVSearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var kind: LibraryKind = .live
    @State private var query = ""
    @State private var store: TVLibraryStore?
    @State private var allItems: [CatalogItem] = []
    @State private var filtered: [CatalogItem] = []
    @State private var playing: CatalogItem?
    @State private var visibleCount = 60

    var body: some View {
        Group {
            if let store { content(store) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: kind, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Search")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                if !model.providerReady {
                    Text("Save your provider in Settings to search.")
                        .foregroundStyle(TVTheme.muted)
                } else {
                    Picker("Library", selection: $kind) {
                        ForEach(LibraryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 480)

                    TextField(kind == .movies ? "Search movies" : "Search channels", text: $query)
                        .frame(maxWidth: 640)

                    if store.loading && allItems.isEmpty {
                        ProgressView(store.progress.isEmpty ? "Loading catalog…" : store.progress)
                    } else if !store.error.isEmpty && allItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.error).foregroundStyle(TVTheme.muted)
                            Button("Retry") { store.revision += 1 }.buttonStyle(.card)
                        }
                    } else {
                        resultsGrid
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .background(TVTheme.background)
        .task(id: "\(kind.rawValue)-\(model.libraryRevision)-\(store.revision)") {
            if store.kind != kind {
                store = TVLibraryStore(kind: kind, model: model)
            }
            store.reset()
            allItems = []; filtered = []; visibleCount = 60
            await store.loadCategories()
            guard !Task.isCancelled else { return }
            await store.loadAllForSearch { partial, message in
                allItems = partial
                applyFilter(items: partial)
                if !message.isEmpty { store.progress = message }
            }
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            applyFilter(items: allItems)
        }
        .fullScreenCover(item: $playing) { item in
            TVPlayerView(item: item, provider: model.provider, channels: kind == .live ? filtered : [])
        }
    }

    @ViewBuilder
    private var resultsGrid: some View {
        let visible = Array(filtered.prefix(visibleCount))
        if filtered.isEmpty {
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Catalog is empty." : "No matching titles.")
                .foregroundStyle(TVTheme.muted)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: kind == .movies ? 220 : 260), spacing: 28)],
                spacing: 32
            ) {
                ForEach(visible) { item in
                    Button { playing = item } label: {
                        TVCatalogCard(item: item)
                    }
                    .buttonStyle(.card)
                }
            }
            if filtered.count > visibleCount {
                Button("Show more (\(filtered.count - visibleCount) remaining)") {
                    visibleCount += 60
                }
                .buttonStyle(.card)
                .padding(.top, 8)
            }
            Text("\(filtered.count) titles")
                .font(.caption)
                .foregroundStyle(TVTheme.muted)
                .padding(.top, 8)
        }
    }

    private func applyFilter(items: [CatalogItem]) {
        let term = query
        visibleCount = 60
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = items
            return
        }
        let snapshot = items
        Task.detached(priority: .userInitiated) {
            let result = CatalogIndex.matches(snapshot, query: term)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.filtered = result
            }
        }
    }
}
