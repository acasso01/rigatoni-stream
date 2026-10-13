import SwiftUI

// Generic tvOS catalog browser used by the Live TV and Movies tabs.
// Same data path as the iPhone build (shared TVLibraryStore / CatalogLoader),
// rebuilt for the Siri Remote: focusable category bar, focusable card grid,
// pin/unpin for Live TV. Pressing a card plays it full-screen; the Menu
// button backs out of the player automatically.
struct TVCatalogBrowser: View {
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
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
    // Movies open their detail on the NavigationStack (single modal level
    // for the player's cover). Live channels play straight from the cover.
    @State private var detailItem: CatalogItem?
    @State private var showingDetail = false

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
        .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: kind, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        HStack(alignment: .top, spacing: 24) {
            categorySidebar(store).frame(width: kind == .live ? 420 : 285).frame(maxHeight: .infinity)
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
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
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
        .navigationDestination(isPresented: $showingDetail) {
            if let item = detailItem { MovieDetailView(item: item) }
        }
    }

    private func loadSelection(_ store: TVLibraryStore) async {
        if selectedCategory == "all" { await store.loadAllForSearch { _, _ in } }
        else { await store.loadItems(categoryID: selectedCategory) }
    }

    private func openDetail(_ item: CatalogItem) {
        detailItem = item
        showingDetail = true
    }

    private func categorySidebar(_ store: TVLibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.title).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 20)
            Text("CATEGORIES").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: kind == .live ? 8 : 12) {
                    if kind == .movies {
                        Button("All titles") { selectedCategory = "all" }.buttonStyle(.bordered)
                    }
                    ForEach(orderedCategories) { category in
                        Button { selectedCategory = category.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: pinnedIDs.contains(category.id) ? "pin.fill" : kind.symbol)
                                    .foregroundStyle(.secondary)
                                Text(category.name).font(.system(size: kind == .live ? 22 : 20, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if selectedCategory == category.id { Image(systemName: "checkmark") }
                            }.padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: kind == .live ? 68 : 60, alignment: .leading)
                        }.buttonStyle(TVCatalogRowStyle(selected: selectedCategory == category.id))
                        .contextMenu {
                            if allowPins {
                                Button(pinnedIDs.contains(category.id) ? "Unpin category" : "Pin category") {
                                    pinnedIDs = CategoryPins.toggled(category.id, in: pinnedIDs)
                                    if let key = store.pinKey { UserDefaults.standard.set(pinnedIDs, forKey: key) }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }.frame(maxHeight: .infinity)
            if allowPins {
                Button(isPinned ? "Unpin category" : "Pin category") {
                    pinnedIDs = CategoryPins.toggled(selectedCategory, in: pinnedIDs)
                    if let key = store.pinKey { UserDefaults.standard.set(pinnedIDs, forKey: key) }
                }.buttonStyle(.bordered).disabled(selectedCategory.isEmpty)
                    .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func itemGrid(_ store: TVLibraryStore) -> some View {
        let shown = store.items.filter(model.preferences.visible)
        let visible = Array(shown.prefix(visibleCount))
        if visible.isEmpty {
            Text("No titles available.").foregroundStyle(TVTheme.muted)
        } else {
            if kind == .live {
                LazyVStack(spacing: 10) {
                    ForEach(visible, id: \.scopedID) { item in
                        Button { playing = item } label: {
                            HStack(spacing: 22) {
                                ProviderPoster(url: item.poster, kind: .live).frame(width: 100, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                Text(item.name).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
                            }.padding(.horizontal, 22).frame(minHeight: 86)
                        }.buttonStyle(TVCatalogRowStyle(selected: false)).focused($focusedCard, equals: item.id)
                        .contextMenu {
                            Button(TVFavorites.contains(item: item, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggle(item: item, model: model) }
                        }
                    }
                }.padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 22)], spacing: 36) {
                    ForEach(visible, id: \.scopedID) { item in
                        Button { openDetail(item) } label: { TVCatalogCard(item: item) }
                            .buttonStyle(TVCardButtonStyle()).focused($focusedCard, equals: item.id)
                            .contextMenu {
                                Button(TVFavorites.contains(item: item, model: model) ? "Remove from Saved" : "Save to Favorites") { TVFavorites.toggle(item: item, model: model) }
                            }
                    }
                }.padding(.vertical, 12)
            }
            if shown.count > visibleCount {
                Button("Show more (\(shown.count - visibleCount) remaining)") {
                    visibleCount += 60
                }
                .buttonStyle(TVCardButtonStyle())
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
    @Environment(\.isFocused) private var focused
    @AppStorage("rigatoni-appearance") private var appearance = "dark"

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
        .foregroundStyle(focused ? Color.white : StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
    }
}

struct TVCatalogRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        TVCatalogRowLabel(configuration: configuration, selected: selected)
    }
}
private struct TVCatalogRowLabel: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    var body: some View {
        configuration.label
            .foregroundStyle(focused ? Color.white : StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .background(focused ? TVTheme.focusFill : (selected ? StreamTheme.accent.opacity(0.22) : StreamTheme.panel), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(StreamTheme.accent).frame(width: 4).padding(.vertical, 12) }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
