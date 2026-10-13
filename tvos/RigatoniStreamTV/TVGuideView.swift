import SwiftUI

// Live TV guide matching the iPhone "All channels" layout: title +
// time-slot bar, category chips with "All" first, and rows of
// star (pin) | channel logo + channel number | NOW program + NEXT program.
// Pins persist per provider in the shared PinnedChannels store, so pinned
// channels sync with the iPhone app. Tapping a row plays the channel.
// Layout language inspired by cable-box guides only — no third-party logos,
// trademarks or copied assets.
struct TVGuideView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var selectedCategory = "all"
    @State private var pinned: Set<String> = []
    @State private var page = 0
    @State private var retry = 0
    @State private var nowTick = Date()
    @State private var playing: CatalogItem?
    @FocusState private var chipFocus: String?

    private let pageSize = 40

    private var selectedName: String {
        if selectedCategory == "all" { return "All channels" }
        return store?.categories.first { $0.id == selectedCategory }?.name ?? "Guide"
    }

    // Pinned channels always float to the top, in every category view.
    private var ordered: [CatalogItem] {
        guard let store else { return [] }
        let visible = store.items.filter(model.preferences.visible)
        return visible.filter { pinned.contains($0.id) } + visible.filter { !pinned.contains($0.id) }
    }

    // Current half-hour window, e.g. "Now – 11:00p" with "11:30p" next.
    private var slot: (end: String, next: String) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: nowTick)
        var startComps = comps
        startComps.minute = (comps.minute ?? 0) < 30 ? 0 : 30
        startComps.second = 0
        let start = cal.date(from: startComps) ?? nowTick
        let end = cal.date(byAdding: .minute, value: 30, to: start) ?? nowTick
        let next = cal.date(byAdding: .minute, value: 30, to: end) ?? nowTick
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"; formatter.amSymbol = "a"; formatter.pmSymbol = "p"
        return (formatter.string(from: end), formatter.string(from: next))
    }

    var body: some View {
        Group {
            if let store { TVObservedStore(store: store) { content($0) }.id(ObjectIdentifier(store)) }
            else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        if !model.providerReady {
            Text("Save your provider in Settings to browse the guide.")
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedName)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(TVTheme.text)
                    .padding(.horizontal, 60)
                    .padding(.top, 36)

                HStack {
                    Text("Now – \(slot.end)")
                        .font(.system(size: 24))
                        .foregroundStyle(TVTheme.muted)
                    Spacer()
                    Text(slot.next)
                        .font(.system(size: 24))
                        .foregroundStyle(TVTheme.muted)
                }
                .padding(.horizontal, 60)
                .padding(.top, 8)

                categoryChips(store)
                    .padding(.top, 12)

                if store.loading && store.items.isEmpty {
                    ProgressView("Loading guide…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !store.error.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(store.error).foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                    }.padding(48)
                } else if ordered.isEmpty {
                    Text("No visible channels in this category.")
                        .foregroundStyle(TVTheme.muted)
                        .font(.system(size: 24))
                        .padding(48)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(ordered.dropFirst(page * pageSize).prefix(pageSize))) { channel in
                                TVGuideRow(channel: channel,
                                          isPinned: pinned.contains(channel.id),
                                          togglePin: { togglePin(channel.id) }) { playing = channel }
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 20)
                    }
                    if ordered.count > pageSize {
                        HStack(spacing: 24) {
                            Button("Previous") { page -= 1 }
                                .disabled(page == 0).buttonStyle(.bordered)
                            Text("Page \(page + 1) of \((ordered.count + pageSize - 1) / pageSize)")
                                .font(.system(size: 22)).foregroundStyle(TVTheme.muted)
                            Button("Next") { page += 1 }
                                .disabled((page + 1) * pageSize >= ordered.count).buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, 24)
                    }
                }
            }
            .foregroundStyle(TVTheme.text)
        }
        .task(id: "\(model.libraryRevision)-\(retry)") {
            pinned = PinnedChannels.read(key: model.preferenceKey)
            await store.loadCategories()
            guard !Task.isCancelled else { return }
            let ids = Set(store.categories.filter { model.preferences.categoryVisible($0.id, kind: .live) }.map(\.id))
            if selectedCategory != "all", !ids.contains(selectedCategory) { selectedCategory = "all" }
        }
        .task(id: "\(selectedCategory)-\(model.libraryRevision)-\(retry)") {
            page = 0
            guard model.providerReady else { return }
            if selectedCategory == "all" { await store.loadAllItems() }
            else { await store.loadItems(categoryID: selectedCategory) }
        }
        .task {
            // Keep the time-slot bar current.
            while !Task.isCancelled {
                nowTick = Date()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .fullScreenCover(item: $playing) { item in
            CatalogDestination(item: item, channels: store.items.filter(model.preferences.visible))
        }
    }

    private func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        PinnedChannels.write(pinned, key: model.preferenceKey)
    }

    // MARK: - Category chips

    private func categoryChips(_ store: TVLibraryStore) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                guideChip(id: "all", name: "All")
                ForEach(store.categories.filter { model.preferences.categoryVisible($0.id, kind: .live) }) { category in
                    guideChip(id: category.id, name: category.name)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 8)
        }
        .focusSection()
        .onAppear {
            // Returning to the Guide with categories already loaded.
            chipFocus = "chip-\(selectedCategory)"
        }
        .onChange(of: selectedCategory) { _, new in
            chipFocus = "chip-\(new)"
        }
    }

    private func guideChip(id: String, name: String) -> some View {
        Button { selectedCategory = id } label: {
            Text(name)
                .font(.system(size: 23, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .buttonStyle(TVCompactButtonStyle())
        .focused($chipFocus, equals: "chip-\(id)")
        .background(selectedCategory == id ? TVTheme.accent : TVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(selectedCategory == id ? Color.white : TVTheme.text)
    }
}

// MARK: - Guide row: star (pin) | logo + channel number | NOW + NEXT

private struct TVGuideRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: CatalogItem
    let isPinned: Bool
    let togglePin: () -> Void
    let play: () -> Void
    @State private var programs: [EPGProgram] = []
    @State private var loading = true
    private var nowNext: EPGNowNext { EPGParser.nowNext(programs) }

    var body: some View {
        HStack(spacing: 20) {
            Button(action: togglePin) {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.system(size: 30))
                    .foregroundStyle(isPinned ? TVTheme.accent : TVTheme.muted)
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(TVCompactButtonStyle())
            .accessibilityLabel(isPinned ? "Unpin channel" : "Pin channel")

            Button(action: play) {
                TVGuideRowLabel(channel: channel, nowNext: nowNext, loading: loading)
            }
            .buttonStyle(TVCompactButtonStyle())
        }
        .task(id: "\(model.libraryRevision)-\(channel.id)") {
            programs = []; loading = true
            guard let scope = model.preferenceKey else { loading = false; return }
            while !Task.isCancelled {
                let loaded = await EPGCache.shared.programs(streamID: channel.id,
                                                            provider: model.provider,
                                                            scope: scope + "-\(model.libraryRevision)")
                guard !Task.isCancelled else { return }
                programs = Array(loaded.filter { $0.end > Date() }.prefix(6)); loading = false
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

private struct TVGuideRowLabel: View {
    @Environment(\.isFocused) private var focused
    let channel: CatalogItem
    let nowNext: EPGNowNext
    let loading: Bool

    var body: some View {
        HStack(spacing: 28) {
            VStack(spacing: 6) {
                ProviderPoster(url: channel.poster, kind: .live)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !channel.number.isEmpty {
                    Text(channel.number)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(focused ? Color.white.opacity(0.85) : TVTheme.muted)
                }
            }
            .frame(width: 140)

            VStack(alignment: .leading, spacing: 8) {
                Text(nowNext.now?.title ?? (loading ? "Loading…" : channel.name))
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                if let next = nowNext.next {
                    Text("Next: \(next.title)")
                        .font(.system(size: 23))
                        .foregroundStyle(focused ? Color.white.opacity(0.75) : TVTheme.muted)
                        .lineLimit(1)
                } else if !loading {
                    Text("Live")
                        .font(.system(size: 23))
                        .foregroundStyle(focused ? Color.white.opacity(0.75) : TVTheme.muted)
                }
            }
            Spacer()
        }
        .foregroundStyle(focused ? Color.white : TVTheme.text)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? TVTheme.focusFill : TVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
