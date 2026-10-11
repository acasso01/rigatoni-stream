import SwiftUI

// Generic tvOS catalog browser used by the Live TV and Movies tabs.
// Same data path as the iPhone build (shared TVLibraryStore / CatalogLoader),
// rebuilt for the Siri Remote: focusable category bar, focusable card grid,
// pin/unpin for Live TV. Pressing a card plays it full-screen; the Menu
// button backs out of the player automatically.
struct TVCatalogBrowser: View {
    let kind: LibraryKind
    let allowPins: Bool
    var initialCategoryID: String? = nil

    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var selectedCategory = ""
    @State private var pinnedIDs: [String] = []
    @State private var playing: CatalogItem?
    @State private var visibleCount = 60
    @FocusState private var focusedCard: String?

    private var orderedCategories: [CatalogCategory] {
        guard let store else { return [] }
        let shown = store.categories.filter { model.preferences.categoryVisible($0.id, kind: kind) }
        return allowPins ? CategoryPins.ordered(shown, pins: pinnedIDs) : shown
    }

    private var selectedName: String {
        selectedCategory == "all" ? "All movies" : orderedCategories.first { $0.id == selectedCategory }?.name ?? ""
    }

    private var isPinned: Bool { pinnedIDs.contains(selectedCategory) }

    var body: some View {
        Group {
            if let store { TVObservedStore(store: store) { content($0) }.id(ObjectIdentifier(store)) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: kind, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        HStack(alignment: .top, spacing: 24) {
            categorySidebar(store).frame(width: 285)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    Text(selectedName.isEmpty ? kind.title : selectedName).font(.title2.bold())
                    if !model.providerReady {
                        Text("Save your provider in Settings to browse.").foregroundStyle(.secondary)
                    } else if store.loading {
                        ProgressView("Loading \(kind.title.lowercased())…").padding(30)
                    } else if !store.error.isEmpty {
                        Text(store.error).foregroundStyle(.secondary)
                        Button("Retry") { store.revision += 1 }.buttonStyle(.bordered)
                    } else { itemGrid(store) }
                }.padding(.vertical, 12).padding(.horizontal, 12)
            }
        }.padding(.horizontal, 24).padding(.top, 12)
        .background { StreamBackdrop() }
        .task(id: "\(model.libraryRevision)-\(store.revision)") {
            let previous = selectedCategory
            await store.loadCategories()
            guard !Task.isCancelled else { return }
            pinnedIDs = store.pinnedIDs()
            if selectedCategory.isEmpty || (selectedCategory != "all" && !orderedCategories.contains(where: { $0.id == selectedCategory })) {
                selectedCategory = initialCategoryID == "all" ? "all" : orderedCategories.first { $0.id == initialCategoryID }?.id ?? orderedCategories.first?.id ?? ""
            }
            if selectedCategory == previous, !selectedCategory.isEmpty {
                await loadSelection(store)
            }
        }
        .task(id: selectedCategory) {
            guard !selectedCategory.isEmpty else { return }
            visibleCount = 60
            await loadSelection(store)
            focusedCard = store.items.first?.id
        }
        .onChange(of: store.items.map(\.id)) { _, ids in
            if focusedCard == nil { focusedCard = ids.first }
        }
        .fullScreenCover(item: $playing) { item in
            CatalogDestination(item: item, channels: kind == .live ? store.items : [])
        }
    }

    private func loadSelection(_ store: TVLibraryStore) async {
        if selectedCategory == "all" { await store.loadAllForSearch { _, _ in } }
        else { await store.loadItems(categoryID: selectedCategory) }
    }

    private func categorySidebar(_ store: TVLibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(kind.title).font(.title2.bold()).padding(.horizontal, 16).padding(.top, 32)
            Text("CATEGORIES").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if kind == .movies {
                        Button("All titles") { selectedCategory = "all" }.buttonStyle(.bordered)
                    }
                    ForEach(orderedCategories) { category in
                        Button { selectedCategory = category.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: pinnedIDs.contains(category.id) ? "pin.fill" : kind.symbol)
                                    .foregroundStyle(.secondary)
                                Text(category.name).font(.callout.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 0)
                                if selectedCategory == category.id { Image(systemName: "checkmark") }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedCategory == category.id ? Color.white.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.card)
                    }
                }.padding(16)
            }
            if allowPins {
                Button(isPinned ? "Unpin category" : "Pin category") {
                    pinnedIDs = CategoryPins.toggled(selectedCategory, in: pinnedIDs)
                    if let key = store.pinKey { UserDefaults.standard.set(pinnedIDs, forKey: key) }
                }.buttonStyle(.bordered).disabled(selectedCategory.isEmpty)
                    .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func itemGrid(_ store: TVLibraryStore) -> some View {
        let shown = store.items.filter(model.preferences.visible)
        let visible = Array(shown.prefix(visibleCount))
        if visible.isEmpty {
            Text("No titles available.").foregroundStyle(TVTheme.muted)
        } else {
            if kind == .live {
                LazyVStack(spacing: 18) {
                    ForEach(visible) { item in
                        Button { playing = item } label: {
                            HStack(spacing: 24) {
                                ProviderPoster(url: item.poster, kind: .live).frame(width: 100, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                Text(item.name).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
                            }.padding(18).foregroundStyle(.primary)
                                .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: TVTheme.corner))
                        }.buttonStyle(.card).focused($focusedCard, equals: item.id)
                    }
                }.padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 22)], spacing: 36) {
                    ForEach(visible) { item in
                        Button { playing = item } label: { TVCatalogCard(item: item) }
                            .buttonStyle(.card).focused($focusedCard, equals: item.id)
                    }
                }.padding(.vertical, 12)
            }
            if shown.count > visibleCount {
                Button("Show more (\(shown.count - visibleCount) remaining)") {
                    visibleCount += 60
                }
                .buttonStyle(.card)
                .padding(.top, 8)
            }
            Text("\(shown.count) titles")
                .font(.caption)
                .foregroundStyle(TVTheme.muted)
                .padding(.top, 8)
        }
    }
}

// One focusable catalog card. Poster loading reuses the shared
// ProviderPoster view (same bounded in-memory fetch as the iPhone build).
struct TVCatalogCard: View {
    let item: CatalogItem

    private var cardWidth: CGFloat { item.kind == .movies ? 200 : 260 }
    private var cardHeight: CGFloat { item.kind == .movies ? 300 : 146 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderPoster(url: item.poster, kind: item.kind)
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(width: cardWidth, alignment: .leading)
        }
        .foregroundStyle(TVTheme.text)
    }
}
