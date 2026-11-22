import SwiftUI
import UIKit
import VLCKit

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
    @FocusState private var catFocus: String?
    @FocusState private var channelFocus: String?
    @Namespace private var channelColumn
    @Environment(\.tvRailAction) private var railAction
    @State private var epgReload = 0
    @State private var epgReloading = false
    @StateObject private var previewPlayer = TVPreviewPlayer()
    @State private var previewItem: CatalogItem?
    @State private var previewNowTitle = ""
    @State private var guideVisible = false
    @State private var pinnedCatIDs: [String] = []
    @State private var visibleCategories: [CatalogCategory] = []
    @State private var visibleChannels: [CatalogItem] = []
    @State private var previewClearTask: Task<Void, Never>?
    /// "All" stays first; pinned categories follow in pin order, then the rest.
    private func orderedCats(_ categories: [CatalogCategory]) -> [CatalogCategory] {
        PinnedCategories.ordered(categories, pins: pinnedCatIDs)
    }

    private let pageSize = 40

    private var selectedName: String {
        if selectedCategory == "all" { return "All Channels" }
        return visibleCategories.first { $0.id == selectedCategory }?.name ?? "Guide"
    }

    // Pinned channels always float to the top, in every category view.
    private var ordered: [CatalogItem] { visibleChannels }

    // Build once for catalog/preference changes, rather than running region
    // matching for every channel on every focus, preview and EPG update.
    private func refreshVisibleContent(_ store: TVLibraryStore) {
        visibleCategories = orderedCats(model.preferences.browseCategories(store.categories, section: .live))
        visibleChannels = TVGuideIndex.channels(store.items, categories: store.categories,
                                               preferences: model.preferences, pinned: pinned)
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
            guideVisible = true
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
        .onDisappear {
            guideVisible = false
            previewClearTask?.cancel()
            previewPlayer.stop()
            previewItem = nil
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        Group {
        if !model.providerReady {
            Text("Save your provider in Settings to browse the guide.")
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selectedName)
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(TVTheme.text)
                            .lineLimit(2)
                        Text(previewItem?.name ?? "Live TV")
                            .font(.system(size: 28, weight: .semibold))
                            .lineLimit(2)
                        Text(previewItem == nil
                             ? "Focus a channel to watch. Select it for fullscreen."
                             : (previewNowTitle.isEmpty ? "Live now" : previewNowTitle))
                            .font(.system(size: 22))
                            .foregroundStyle(TVTheme.muted)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    previewPane()
                    Button { reloadEPG() } label: {
                        if epgReloading {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 64, height: 64)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 28, weight: .semibold))
                                .frame(width: 64, height: 64)
                        }
                    }
                    .buttonStyle(TVCompactButtonStyle())
                    .accessibilityLabel("Reload program guide")
                    .disabled(epgReloading)
                }
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .padding(.bottom, 12)

                HStack(alignment: .top, spacing: 32) {
                    categoryList(store)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Now – \(slot.end)")
                            Spacer()
                            Text(slot.next)
                        }
                        .font(.system(size: 22))
                        .foregroundStyle(TVTheme.muted)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

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
                            let pageItems = Array(ordered.dropFirst(page * pageSize).prefix(pageSize))
                            ScrollView {
                                // One bounded page (40 rows): keep all directional
                                // targets mounted so Down cannot target an absent lazy row.
                                VStack(spacing: 12) {
                                    ForEach(pageItems, id: \.scopedID) { channel in
                                        TVGuideRow(channel: channel,
                                                  refreshToken: epgReload,
                                                  isPinned: pinned.contains(channel.scopedID),
                                                  togglePin: { togglePin(channel.scopedID) },
                                                  onHover: { focused in updatePreview(channel, focused: focused) },
                                                  channelFocus: $channelFocus,
                                                  onLeaveLeft: { catFocus = "cat-\(selectedCategory)" }) { playChannel(channel) }
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if ordered.count > pageSize {
                                HStack(spacing: 24) {
                                    Button("Previous") { page -= 1 }
                                        .disabled(page == 0).buttonStyle(.bordered)
                                    Text("Page \(page + 1) of \((ordered.count + pageSize - 1) / pageSize)")
                                        .font(.system(size: 22)).foregroundStyle(TVTheme.muted)
                                    Button("Next") { page += 1 }
                                        .disabled((page + 1) * pageSize >= ordered.count).buttonStyle(.bordered)
                                }
                                .padding(.bottom, 12)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .focusSection()
                    .focusScope(channelColumn)
                }
                .padding(.horizontal, 40)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(TVTheme.text)
        }
        }
        .onChange(of: store.contentRevision, initial: true) { _, _ in refreshVisibleContent(store) }
        .onChange(of: model.libraryRevision) { _, _ in refreshVisibleContent(store) }
        .onChange(of: pinned) { _, _ in refreshVisibleContent(store) }
        .onChange(of: pinnedCatIDs) { _, _ in refreshVisibleContent(store) }
        .onExitCommand {
            previewClearTask?.cancel()
            previewItem = nil
            previewPlayer.stop()
            railAction.returnToRail()
        }
        .task(id: "\(model.libraryRevision)-\(retry)") {
            pinned = PinnedChannels.read(key: model.preferenceKey)
            pinnedCatIDs = PinnedCategories.read(key: model.pinKey)
            await store.loadCategories()
            guard !Task.isCancelled else { return }
            let ids = Set(model.preferences.browseCategories(store.categories, section: .live).map(\.id))
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
        .task(id: "\(previewItem?.scopedID ?? "-")-\(model.libraryRevision)-\(guideVisible)-\(playing?.scopedID ?? "-")") {
            previewNowTitle = ""
            guard let item = previewItem, model.providerReady, guideVisible, playing == nil else {
                previewPlayer.stop()
                return
            }
            // Debounce so fast scrolling doesn't thrash streams.
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            do {
                let url = try model.provider(for: item).streamURL(item: item)
                try Task.checkCancellation()
                guard guideVisible, playing == nil, previewItem?.scopedID == item.scopedID else { return }
                previewPlayer.play(url: url)
                // Best-effort "now playing" label; must not block video.
                let progs = await EPGCache.shared.programs(streamID: item.id, provider: model.provider(for: item), scope: model.epgScope(for: item), categoryID: item.categoryID)
                if !Task.isCancelled {
                    previewNowTitle = EPGParser.nowNext(progs).now?.title ?? ""
                }
            } catch {
                if !Task.isCancelled { previewPlayer.failed = true }
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            previewPlayer.stop()
            previewItem = nil
        }
        .fullScreenCover(item: $playing) { item in
            CatalogDestination(item: item, channels: store.items.filter(model.preferences.visible))
        }
    }

    private func updatePreview(_ channel: CatalogItem, focused: Bool) {
        guard guideVisible, playing == nil else { return }
        if focused {
            previewClearTask?.cancel()
            guard previewItem?.scopedID != channel.scopedID else { return }
            // The playback task debounces before replacing the old stream.
            previewItem = channel
        } else if previewItem?.scopedID == channel.scopedID {
            previewClearTask?.cancel()
            previewClearTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled, previewItem?.scopedID == channel.scopedID else { return }
                previewItem = nil
            }
        }
    }

    private func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        PinnedChannels.write(pinned, key: model.preferenceKey)
    }

    // Stop the preview before opening fullscreen so only one stream plays audio.
    private func playChannel(_ channel: CatalogItem) {
        previewPlayer.stop()
        previewItem = nil
        previewNowTitle = ""
        playing = channel
    }

    // MARK: - Category list (vertical, scrolls down like the concept)

    private func categoryList(_ store: TVLibraryStore) -> some View {
        let ids = ["all"] + visibleCategories.map(\.id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TVTheme.muted)
                .padding(.horizontal, 4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ids, id: \.self) { id in
                        let name = id == "all" ? "All" : (visibleCategories.first { $0.id == id }?.name ?? "Category")
                        if id == "all" {
                            TVEntryControl(section: .guide) {
                                TVEntryControl(section: .live) {
                                    categoryRow(id: id, name: name)
                                }
                            }
                        } else {
                            categoryRow(id: id, name: name)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 400)
        .focusSection()
        .onAppear { catFocus = "cat-\(selectedCategory)" }
        .onChange(of: selectedCategory) { _, new in
            catFocus = "cat-\(new)"
        }
    }

    private func categoryRow(id: String, name: String) -> some View {
        Button { selectedCategory = id } label: {
            HStack {
                Text((id != "all" && pinnedCatIDs.contains(id) ? "★ " : "") + name)
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(TVCompactButtonStyle())
        .focused($catFocus, equals: "cat-\(id)")
        .accessibilityIdentifier("guide-category-\(id)")
        .onMoveCommand { direction in
            // tvOS owns Up/Down. A second FocusState assignment here can
            // move again after a physical remote has already advanced a row.
            switch direction {
            case .right:
                if let first = ordered.dropFirst(page * pageSize).first {
                    TVColumnFocus.keep($channelFocus, first.scopedID)
                }
            case .left: railAction.returnToRail()
            default: break
            }
        }
        .background(selectedCategory == id ? AnyShapeStyle(TVTheme.accentFill) : AnyShapeStyle(TVTheme.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(selectedCategory == id ? TVTheme.onAccent : TVTheme.text)
        .contextMenu {
            if id != "all" {
                Button(pinnedCatIDs.contains(id) ? "Unpin category" : "Pin category to front") {
                    pinnedCatIDs = PinnedCategories.toggled(id, in: pinnedCatIDs)
                    PinnedCategories.write(pinnedCatIDs, key: model.pinKey)
                }
            }
        }
    }

    // Manual EPG reload: clear the cache so stale programs can't stick,
    // then restart every visible row's EPG task so it refetches fresh.
    private func reloadEPG() {
        guard !epgReloading else { return }
        Task { @MainActor in
            epgReloading = true
            EPGCache.shared.reset()
            epgReload += 1
            try? await Task.sleep(for: .seconds(1))
            epgReloading = false
        }
    }
}

// MARK: - Guide row: star (pin) | logo + channel number | NOW + NEXT

private struct TVGuideRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: CatalogItem
    let refreshToken: Int
    let isPinned: Bool
    let togglePin: () -> Void
    let onHover: (Bool) -> Void
    var channelFocus: FocusState<String?>.Binding
    var onLeaveLeft: () -> Void
    @FocusState private var focusedControl: String?
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
            .focused($focusedControl, equals: "pin")
            .onMoveCommand { direction in
                switch direction {
                case .right: TVColumnFocus.keep(channelFocus, channel.scopedID)
                case .left: onLeaveLeft()
                default: break
                }
            }

            Button(action: play) {
                TVGuideRowLabel(channel: channel, nowNext: nowNext, loading: loading)
            }
            .buttonStyle(TVCompactButtonStyle())
            .focused(channelFocus, equals: channel.scopedID)
            .accessibilityIdentifier("guide-channel-\(channel.scopedID)")
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    channelFocus.wrappedValue = nil
                    focusedControl = "pin"
                default: break
                }
            }
        }
        .onChange(of: focusedControl) { _, control in onHover(control != nil || channelFocus.wrappedValue == channel.scopedID) }
        .onChange(of: channelFocus.wrappedValue) { _, value in onHover(value == channel.scopedID || focusedControl != nil) }
        .onDisappear { onHover(false) }
        .task(id: "\(model.libraryRevision)-\(channel.scopedID)-\(refreshToken)") {
            programs = []; loading = true
            while !Task.isCancelled {
                let loaded = await EPGCache.shared.programs(streamID: channel.id,
                                                            provider: model.provider(for: channel),
                                                            scope: model.epgScope(for: channel),
                                                            categoryID: channel.categoryID)
                guard !Task.isCancelled else { return }
                programs = Array(loaded.filter { $0.end > Date() }.prefix(6)); loading = false
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

private struct TVGuideRowLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.isFocused) private var focused
    let channel: CatalogItem
    let nowNext: EPGNowNext
    let loading: Bool

    var body: some View {
        HStack(spacing: 28) {
            VStack(spacing: 6) {
                ProviderPoster(url: channel.poster, kind: .live)
                    .frame(width: 104, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !channel.number.isEmpty {
                    Text(channel.number)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(focused ? Color.white.opacity(0.85) : TVTheme.muted)
                }
            }
            .frame(width: 124)

            VStack(alignment: .leading, spacing: 8) {
                Text(nowNext.now?.title ?? (loading ? "Loading…" : model.preferences.itemTitle(channel)))
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
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? TVTheme.focusFill : TVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Hover preview pane

extension TVGuideView {
    // 16:9 muted preview beside the guide heading. Shows the focused
    // channel's live stream; one click on the row still goes fullscreen with sound.
    @ViewBuilder
    fileprivate func previewPane() -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(TVTheme.card)
                .frame(width: 520, height: 292.5)
            if let item = previewItem {
                if previewPlayer.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(TVTheme.muted)
                        Text("Preview unavailable")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(TVTheme.muted)
                        Text(model.preferences.itemTitle(item))
                            .font(.system(size: 20))
                            .foregroundStyle(TVTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(width: 520, height: 292.5)
                } else {
                    TVPreviewSurface(player: previewPlayer)
                        .frame(width: 520, height: 292.5)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    if !previewPlayer.playing {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 520, height: 292.5)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                        .frame(width: 520, height: 292.5)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("PREVIEW")
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.22), in: Capsule())
                            Label("MUTED", systemImage: "speaker.slash.fill")
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.22), in: Capsule())
                        }
                        Text(model.preferences.itemTitle(item))
                            .font(.system(size: 27, weight: .semibold))
                            .lineLimit(1)
                        Text(previewNowTitle.isEmpty ? "Live" : previewNowTitle)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(22)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tv")
                        .font(.system(size: 44))
                        .foregroundStyle(TVTheme.muted)
                    Text("Focus a channel to preview it live")
                        .font(.system(size: 22))
                        .foregroundStyle(TVTheme.muted)
                }
                .frame(width: 520, height: 292.5)
            }
        }
        .frame(width: 520, height: 292.5)
    }
}

// MARK: - Hover preview player (VLC)

// One muted VLC preview. Pending starts are cancelled by the guide's
// debounced task; focus loss and fullscreen playback stop this player.
@MainActor
final class TVPreviewPlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ProviderHTTP.playerArguments(extra: ["--no-audio"]))
    @Published var playing = false
    @Published var failed = false
    private var timer: Timer?
    private var activeURL: URL?

    func attach(_ view: UIView) { engine.drawable = view }

    func play(url: URL) {
        guard activeURL != url else { return }
        stop()
        activeURL = url
        failed = false
        playing = false
        guard let media = VLCMedia(url: url) else { failed = true; return }
        media.addOptions(ProviderHTTP.mediaOptions(cache: 1500))
        engine.media = media
        engine.play()
        timer?.invalidate()
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.timer != nil else { return }
                if self.engine.state == .error {
                    self.fail()
                } else if self.engine.isPlaying {
                    self.playing = true
                } else if Date().timeIntervalSince(started) > 20 {
                    self.fail()
                }
            }
        }
    }

    func stop() {
        guard activeURL != nil else { return }
        activeURL = nil
        timer?.invalidate()
        timer = nil
        playing = false
        engine.stop()
    }

    private func fail() {
        stop()
        failed = true
    }
}

// Plain non-interactive UIView hosting the preview player's drawable.
// User interaction is disabled so the Siri Remote focus stays on the rows.
private struct TVPreviewSurface: UIViewRepresentable {
    let player: TVPreviewPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// Region/category decisions are evaluated once per category, not once per
// channel per redraw. Unknown and untagged category IDs retain existing rules.
enum TVGuideIndex {
    static func channels(_ items: [CatalogItem], categories: [CatalogCategory],
                         preferences: LibraryPreferences, pinned: Set<String>) -> [CatalogItem] {
        let known = Set(categories.map(\.id))
        let allowed = Set(categories.filter { preferences.allows($0, section: .live) }.map(\.id))
        let nonEnglish = Set(categories.filter { preferences.hideNonEnglishCategories && CategoryRegion.isNonEnglish($0.name) }.map(\.id))
        var first: [CatalogItem] = []
        var rest: [CatalogItem] = []
        for item in items where preferences.visible(item) {
            guard !nonEnglish.contains(item.categoryID) else { continue }
            guard item.categoryID.isEmpty || !known.contains(item.categoryID) || allowed.contains(item.categoryID)
                    || (preferences.unitedStatesOnly && CategoryRegion.isEnglish(item.name)) else { continue }
            if pinned.contains(item.scopedID) { first.append(item) } else { rest.append(item) }
        }
        return first + rest
    }
}
