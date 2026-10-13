import SwiftUI

enum MobileSection: String, CaseIterable, Identifiable {
    case home, guide, live, movies, shows, saved, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .guide: return "Guide"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .saved: return "Saved"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .guide: return "square.grid.2x2"
        case .live: return "tv"
        case .movies: return "film"
        case .shows: return "play.tv"
        case .saved: return "bookmark"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: MobileSection = .home
    @State private var more = false
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch section {
                case .home: MobileHomeView(select: { section = $0 })
                case .guide: MobileGuideView()
                case .live: LibraryView(kind: .live)
                case .movies: MoviesHomeView()
                case .shows: ShowsView()
                case .saved: MobileSavedView()
                case .search: GlobalSearchView()
                case .settings: SettingsView()
                }
            }.id(appearance).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                ForEach([MobileSection.home, .live, .movies, .shows, .search]) { entry in
                    Button { section = entry } label: {
                        navLabel(entry.title, symbol: entry.symbol, selected: section == entry)
                    }.accessibilityAddTraits(section == entry ? .isSelected : [])
                }
                Button { more = true } label: {
                    navLabel("More", symbol: "ellipsis.circle", selected: [.guide, .saved, .settings].contains(section))
                }
            }
            .buttonStyle(.plain).padding(.top, 10).padding(.bottom, 6)
            .background(.regularMaterial)
        }
        .sheet(isPresented: $more) {
            NavigationStack {
                List(MobileSection.allCases) { entry in
                    Button {
                        more = false
                        if entry == .settings {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                model.settingsVisible = true
                            }
                        } else { section = entry }
                    } label: {
                        HStack {
                            Label(entry.title, systemImage: entry.symbol)
                            Spacer()
                            if entry == section { Image(systemName: "checkmark") }
                        }.foregroundStyle(StreamTheme.text)
                    }
                }.navigationTitle("Ant Streams")
                    .toolbar { Button("Done") { more = false } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.settingsVisible) { SettingsView() }
    }
    private func navLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 21))
            Text(title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(selected ? StreamTheme.accent : StreamTheme.muted)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct MobileHero: View {
    let title: String
    let poster: URL?
    var badge = "IN THE SPOTLIGHT"
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ProviderPoster(url: poster, kind: .movies).frame(height: 290).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text(badge).font(.caption.bold()).tracking(2)
                Text(title).font(.title2.bold()).lineLimit(3)
                Label("View details", systemImage: "info.circle").font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(.black).background(.white, in: Capsule())
            }.padding(22).foregroundStyle(.white)
        }.frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

@MainActor
enum MobileRecords {
    static func key(_ model: AppModel, history: Bool = false) -> String? {
        model.preferenceKey.map { $0 + (history ? "-mobile-history-v1" : "-favorites-v2") }
    }
    static func record(_ item: CatalogItem, kind: String? = nil) -> SavedRecord {
        SavedRecord(kind: kind ?? (item.kind == .live ? "live" : "movie"), itemID: item.id,
                    name: item.name, ext: item.fileExtension, categoryID: item.categoryID, addedAt: Date())
    }
    static func visible(_ record: SavedRecord, model: AppModel) -> Bool {
        record.kind == "series" || record.kind == "episode" || model.preferences.visible(
            CatalogItem(id: record.itemID, name: record.name, kind: record.kind == "live" ? .live : .movies,
                        fileExtension: record.ext, poster: nil, categoryID: record.categoryID))
    }
    static func watched(_ item: CatalogItem, episode: Bool, model: AppModel) {
        guard let key = key(model, history: true) else { return }
        let entry = record(item, kind: episode ? "episode" : nil)
        var records = SavedCollection.items(key: key).filter { $0.id != entry.id }
        records.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(Array(records.prefix(24))) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct MobileSaveButton: View {
    @EnvironmentObject private var model: AppModel
    let record: SavedRecord
    @State private var saved = false
    var body: some View {
        Button {
            saved = SavedCollection.toggle(record, key: MobileRecords.key(model))
        } label: {
            Label(saved ? "Remove from Saved" : "Add to Saved", systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .disabled(model.preferenceKey == nil)
        .onAppear { saved = SavedCollection.items(key: MobileRecords.key(model)).contains { $0.id == record.id } }
    }
}

struct MobileHomeView: View {
    @EnvironmentObject private var model: AppModel
    let select: (MobileSection) -> Void
    @State private var categories: [CatalogCategory] = []
    @State private var error = ""
    @State private var retry = 0
    private var pinned: [CatalogCategory] {
        guard let key = model.pinKey else { return [] }
        let pins = UserDefaults.standard.stringArray(forKey: key) ?? []
        return CategoryPins.ordered(categories.filter { pins.contains($0.id) && model.preferences.categoryVisible($0.id, kind: .live) }, pins: pins)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    StreamHeading(title: "Welcome home", subtitle: "Your channels, movies and shows.").padding(.top, 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([MobileSection.guide, .shows, .saved]) { entry in
                                Button { select(entry) } label: { Label(entry.title, systemImage: entry.symbol).padding(12) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    if !model.providerReady {
                        Button("Add your provider to start watching") { model.settingsVisible = true }.buttonStyle(.borderedProminent)
                    } else {
                        MobileSavedContent(history: true)
                        Text("Pinned live categories").font(.title2.bold())
                        if pinned.isEmpty { Text("Pin categories in Live TV to see them here.").foregroundStyle(.secondary) }
                        ForEach(pinned) { category in MobilePinnedShelf(category: category) }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }
                }.padding(18)
            }.background { StreamBackdrop() }
                .navigationTitle("Ant Streams").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button { model.settingsVisible = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account settings") }
                .task(id: "\(model.libraryRevision)-\(retry)") {
                    categories = []; error = ""
                    guard model.providerReady else { return }
                    do {
                        let loaded = try await model.catalog.categories(kind: .live, model: model)
                        try Task.checkCancellation(); categories = loaded
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
        }
    }
}

struct MobilePinnedShelf: View {
    @EnvironmentObject private var model: AppModel
    let category: CatalogCategory
    @State private var items: [CatalogItem] = []
    @State private var playing: CatalogItem?
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { LibraryView(kind: .live, initialCategoryID: category.id, embedded: true) } label: {
                HStack { Text(category.name).font(.headline); Spacer(); Image(systemName: "chevron.right") }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items.prefix(20)) { item in
                        Button { playing = item } label: {
                            VStack(alignment: .leading) {
                                ProviderPoster(url: item.poster, kind: .live).frame(width: 160, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.name).font(.subheadline.bold()).lineLimit(2).frame(width: 160, alignment: .leading)
                            }
                        }.buttonStyle(.plain).contextMenu { MobileSaveButton(record: MobileRecords.record(item)) }
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: "\(category.id)-\(model.libraryRevision)") {
            items = []; error = ""
            do {
                let loaded = try await model.catalog.items(kind: .live, category: category.id, model: model)
                try Task.checkCancellation(); items = loaded.filter(model.preferences.visible)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .fullScreenCover(item: $playing) { CatalogDestination(item: $0, channels: items) }
    }
}


// Starred (pinned) live channels now live in Core.swift (shared with tvOS).
struct MobileGuideView: View {
    @EnvironmentObject private var model: AppModel
    @State private var categories: [CatalogCategory] = []
    @State private var selected = "all"
    @State private var items: [CatalogItem] = []
    @State private var pinned: Set<String> = []
    @State private var loading = false
    @State private var error = ""
    @State private var playing: CatalogItem?
    @State private var page = 0
    @State private var retry = 0
    @State private var nowTick = Date()
    private var selectedName: String {
        if selected == "all" { return "All channels" }
        return categories.first { $0.id == selected }?.name ?? "Guide"
    }
    // Pinned channels always float to the top, in every category view.
    private var ordered: [CatalogItem] {
        items.filter { pinned.contains($0.id) } + items.filter { !pinned.contains($0.id) }
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
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    StreamHeading(title: selectedName, subtitle: "On now and coming up.")
                    if !model.providerReady {
                        Button("Add your provider") { model.settingsVisible = true }
                    }
                    HStack {
                        Text("Now – \(slot.end)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(slot.next).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            guidePill(id: "all", name: "All")
                            ForEach(categories) { category in
                                guidePill(id: category.id, name: category.name)
                            }
                        }
                    }
                    if loading { ProgressView("Loading guide…") }
                    if !error.isEmpty { Text(error); Button("Retry") { retry += 1 } }
                    if !loading && ordered.isEmpty && error.isEmpty && model.providerReady { Text("No visible channels in this category.").foregroundStyle(.secondary) }
                    ForEach(Array(ordered.dropFirst(page * 40).prefix(40))) { item in
                        MobileGuideRow(item: item, pinned: pinned.contains(item.id), togglePin: { togglePin(item.id) }) { playing = item }
                    }
                    if ordered.count > 40 {
                        HStack {
                            Button("Previous") { page -= 1 }.disabled(page == 0)
                            Spacer(); Text("Page \(page + 1)").font(.caption); Spacer()
                            Button("Next") { page += 1 }.disabled((page + 1) * 40 >= ordered.count)
                        }
                    }
                }.padding(18)
            }.background { StreamBackdrop() }
                .navigationTitle("Guide").navigationBarTitleDisplayMode(.inline)
                .task(id: "\(model.libraryRevision)-\(retry)") {
                    categories = []; items = []; selected = "all"; error = ""
                    guard model.providerReady else { return }
                    pinned = PinnedChannels.read(key: model.preferenceKey)
                    do {
                        let loaded = try await model.catalog.categories(kind: .live, model: model)
                        try Task.checkCancellation()
                        categories = loaded.filter { model.preferences.categoryVisible($0.id, kind: .live) }
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
                .task(id: "\(selected)-\(model.libraryRevision)-\(retry)") {
                    items = []; page = 0
                    guard model.providerReady else { return }
                    loading = true; defer { loading = false }
                    do {
                        let loaded: [CatalogItem]
                        if selected == "all" {
                            loaded = try await model.catalog.items(kind: .live, category: nil, model: model)
                        } else {
                            loaded = try await model.catalog.items(kind: .live, category: selected, model: model)
                        }
                        try Task.checkCancellation(); items = loaded.filter(model.preferences.visible); error = ""
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        nowTick = Date()
                    }
                }
                .fullScreenCover(item: $playing) { CatalogDestination(item: $0, channels: items) }
        }
    }
    private func guidePill(id: String, name: String) -> some View {
        Button { selected = id } label: {
            Text(name).font(.subheadline.bold()).lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(selected == id ? AnyShapeStyle(StreamTheme.accentFill) : AnyShapeStyle(StreamTheme.panel), in: Capsule())
                .foregroundStyle(selected == id ? StreamTheme.onAccent : StreamTheme.text)
        }.buttonStyle(.plain)
    }
    private func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        PinnedChannels.write(pinned, key: model.preferenceKey)
    }
}

struct MobileGuideRow: View {
    @EnvironmentObject private var model: AppModel
    let item: CatalogItem
    let pinned: Bool
    let togglePin: () -> Void
    let play: () -> Void
    @State private var programs: [EPGProgram] = []
    @State private var loading = true
    private var nowNext: EPGNowNext { EPGParser.nowNext(programs) }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePin) {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(pinned ? StreamTheme.accent : StreamTheme.muted)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(pinned ? "Unpin channel" : "Pin channel")
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    ProviderPoster(url: item.poster, kind: .live).frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                    if !item.number.isEmpty {
                        Text(item.number).font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(width: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nowNext.now?.title ?? (loading ? "Loading…" : item.name))
                        .font(.headline).lineLimit(1)
                    if let next = nowNext.next {
                        Text(next.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    } else if !loading {
                        Text("Live").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: play)
        }
        .padding(10)
        .background(StreamTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu { MobileSaveButton(record: MobileRecords.record(item)) }
        .task(id: "\(model.libraryRevision)-\(item.id)") {
            programs = []; loading = true
            guard let scope = model.preferenceKey else { loading = false; return }
            while !Task.isCancelled {
                let loaded = await EPGCache.shared.programs(streamID: item.id, provider: model.provider, scope: scope + "-\(model.libraryRevision)")
                guard !Task.isCancelled else { return }
                programs = Array(loaded.filter { $0.end > Date() }.prefix(6)); loading = false
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

struct MobileSavedView: View {
    var body: some View {
        NavigationStack {
            ScrollView { MobileSavedContent().padding(18) }
                .background { StreamBackdrop() }.navigationTitle("Saved")
        }
    }
}

struct MobileShowRequest: Identifiable {
    var id: String { series.id }
    let series: SeriesItem
    let store: SeriesStore
}

struct MobileSavedContent: View {
    @EnvironmentObject private var model: AppModel
    var history = false
    @State private var records: [SavedRecord] = []
    @State private var playing: CatalogItem?
    @State private var episode = false
    @State private var show: MobileShowRequest?
    @State private var notice = ""
    @State private var connecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if history { Text("Last watched").font(.title2.bold()) }
            if records.isEmpty {
                Text(history ? "Watch something to find it here." : "Hold a channel, movie or show and choose Add to Saved.")
                    .foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                Button { Task { await open(record) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: record.kind == "live" ? "tv" : record.kind == "movie" ? "film" : "play.tv")
                            .font(.title2).frame(width: 56, height: 64)
                            .background(StreamTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.name).font(.headline).lineLimit(2)
                            if let progress = model.preferences.progress[(record.kind == "episode" ? "series-" : "") + record.itemID], record.kind != "live" {
                                Text("Continue from \(progress.label)").font(.caption).foregroundStyle(.secondary)
                            } else { Text(record.kind == "live" ? "Live TV" : record.kind == "movie" ? "Movie" : "TV Show").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Image(systemName: "chevron.right")
                    }.foregroundStyle(StreamTheme.text)
                }.buttonStyle(.plain).disabled(connecting)
                    .contextMenu {
                        Button(history ? "Remove from history" : "Remove from Saved", role: .destructive) {
                            SavedCollection.toggle(record, key: MobileRecords.key(model, history: history)); reload()
                        }
                    }
            }
            if connecting { ProgressView("Opening…") }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: reload)
        .onChange(of: model.libraryRevision) { _, _ in reload() }
        .fullScreenCover(item: $playing, onDismiss: reload) { item in
            if episode {
                DirectPlayerView(item: item, provider: model.provider, startSeconds: model.preferences.progress["series-" + item.id]?.seconds ?? 0, progressID: "series-" + item.id)
            } else { CatalogDestination(item: item) }
        }
        .sheet(item: $show) { request in
            NavigationStack {
                ShowDetailView(series: request.series, store: request.store)
                    .toolbar { Button("Done") { show = nil } }
            }
        }
    }
    private func reload() {
        records = SavedCollection.items(key: MobileRecords.key(model, history: history)).filter { MobileRecords.visible($0, model: model) }
        notice = ""
    }
    private func open(_ record: SavedRecord) async {
        notice = ""; connecting = true; defer { connecting = false }
        guard model.providerReady else { notice = "Save your provider in Settings first."; return }
        let scope = model.preferenceKey
        if record.kind == "series" {
            guard model.provider.kind == .xtream else { notice = "TV Shows requires an Xtream Codes provider."; return }
            show = MobileShowRequest(series: SeriesItem(id: record.itemID, name: record.name, poster: nil), store: SeriesStore(model: model)); return
        }
        var item = CatalogItem(id: record.itemID, name: record.name, kind: record.kind == "live" ? .live : .movies,
                               fileExtension: record.ext, poster: nil, categoryID: record.categoryID)
        do {
            if record.kind == "episode" {
                guard model.provider.kind == .xtream else { throw AppFailure("This episode requires an Xtream Codes provider.") }
                item.playbackURL = try SeriesStore.seriesStreamURL(provider: model.provider, episodeID: record.itemID, ext: record.ext)
            } else { item = try await model.resolve(item) }
            guard scope == model.preferenceKey else { return }
            episode = record.kind == "episode"; playing = item
        } catch { if scope == model.preferenceKey { notice = error.localizedDescription } }
    }
}
