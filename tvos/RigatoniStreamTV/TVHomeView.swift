import SwiftUI

// Home tab: quick-access rows for pinned Live TV categories.
// Pinning happens in Live TV; category IDs are stored locally on this Apple TV.
struct TVHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var playing: CatalogItem?

    var body: some View {
        Group {
            if let store {
                TVHomeBody(store: store, model: model, playing: $playing)
                    .fullScreenCover(item: $playing) { item in
                        TVPlayerView(item: item, provider: model.provider, channels: store.items)
                    }
            } else {
                ProgressView("Loading…")
            }
        }
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }
}

private struct TVHomeBody: View {
    @ObservedObject var store: TVLibraryStore
    @ObservedObject var model: AppModel
    @Binding var playing: CatalogItem?

    private var pinned: [CatalogCategory] {
        let ids = Set(store.pinnedIDs())
        return CategoryPins.ordered(store.categories, pins: store.pinnedIDs())
            .filter { ids.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("🍝 RIGATONI STREAM")
                        .font(.title.weight(.black))
                    Text("Your channels, your favorites, one familiar place.")
                        .foregroundStyle(TVTheme.muted)
                }
                .padding(.top, 40)

                if !model.providerReady {
                    Text("Save your provider in Settings to start watching.")
                        .foregroundStyle(TVTheme.muted)
                } else if store.loading && store.categories.isEmpty {
                    ProgressView(store.progress.isEmpty ? "Loading…" : store.progress)
                } else if pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pin categories in Live TV for quick access here.")
                            .foregroundStyle(TVTheme.muted)
                    }
                } else {
                    ForEach(pinned) { category in
                        TVPinnedRow(category: category, model: model, playing: $playing)
                    }
                }

                if !store.error.isEmpty { Text(store.error).foregroundStyle(TVTheme.muted) }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .background(TVTheme.background)
        .task(id: model.libraryRevision) {
            await store.loadCategories()
        }
    }
}

// One pinned category's horizontal row of channel cards.
private struct TVPinnedRow: View {
    let category: CatalogCategory
    @ObservedObject var model: AppModel
    @Binding var playing: CatalogItem?
    @State private var items: [CatalogItem] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.name).font(.title2.bold())
            if loading {
                ProgressView().frame(height: 120)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(items.prefix(20)) { item in
                            Button { playing = item } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProviderPoster(url: item.poster, kind: .live)
                                        .frame(width: 240, height: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
                                    Text(item.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .frame(width: 240, alignment: .leading)
                                }
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .task {
            loading = true
            defer { loading = false }
            do {
                // Lightweight per-row fetch using the shared catalog types.
                if model.provider.requiresGateway {
                    let raw = try await model.gatewayRows(kind: .live, category: category.id)
                    items = raw.compactMap { CatalogItem.parse($0, kind: .live) }.map {
                        var item = $0
                        item.playbackURL = try? model.gatewayPlaybackURL(id: item.id, kind: .live)
                        return item
                    }
                } else {
                    let url = try model.provider.apiURL(action: LibraryKind.live.streamAction, category: category.id)
                    let data = try await BoundedTransfer(limit: 32 * 1024 * 1024).fetch(url)
                    guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
                    items = raw.compactMap { CatalogItem.parse($0, kind: .live) }
                }
            } catch { items = [] }
        }
    }
}
