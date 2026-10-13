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
    @FocusState private var chipFocus: String?
    @StateObject private var previewPlayer = TVPreviewPlayer()
    @State private var previewItem: CatalogItem?
    @State private var previewNowTitle = ""

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
        .onDisappear {
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

                previewPane()

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
                                          togglePin: { togglePin(channel.id) },
                                          onHover: { previewItem = $0 }) { playChannel(channel) }
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
        .task(id: "\(previewItem?.id ?? "-")-\(model.libraryRevision)") {
            previewPlayer.failed = false
            previewNowTitle = ""
            guard let item = previewItem, model.providerReady else {
                previewPlayer.stop()
                return
            }
            // Debounce so fast scrolling doesn't thrash streams.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            do {
                let url = try model.provider.streamURL(item: item)
                try Task.checkCancellation()
                previewPlayer.play(url: url)
                // Best-effort "now playing" label; must not block video.
                if let scope = model.preferenceKey {
                    let progs = await EPGCache.shared.programs(streamID: item.id, provider: model.provider, scope: scope + "-\(model.libraryRevision)")
                    if !Task.isCancelled {
                        previewNowTitle = EPGParser.nowNext(progs).now?.title ?? ""
                    }
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

    private func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        PinnedChannels.write(pinned, key: model.preferenceKey)
    }

    // One click on a row: stop the muted preview and go fullscreen with audio.
    private func playChannel(_ channel: CatalogItem) {
        previewPlayer.stop()
        previewItem = nil
        previewNowTitle = ""
        playing = channel
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
    let onHover: (CatalogItem?) -> Void
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
            .onFocusChange { onHover($0 ? channel : nil) }

            Button(action: play) {
                TVGuideRowLabel(channel: channel, nowNext: nowNext, loading: loading)
            }
            .buttonStyle(TVCompactButtonStyle())
            .onFocusChange { onHover($0 ? channel : nil) }
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

// MARK: - Hover preview pane

extension TVGuideView {
    // 16:9 muted preview pinned above the channel rows. Shows the focused
    // channel's live stream; one click on the row still goes fullscreen.
    @ViewBuilder
    fileprivate func previewPane() -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(TVTheme.card)
                .frame(width: 600, height: 338)
            if let item = previewItem {
                if previewPlayer.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(TVTheme.muted)
                        Text("Preview unavailable")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(TVTheme.muted)
                        Text(item.name)
                            .font(.system(size: 20))
                            .foregroundStyle(TVTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(width: 600, height: 338)
                } else {
                    TVPreviewSurface(player: previewPlayer)
                        .frame(width: 600, height: 338)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    if !previewPlayer.playing {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 600, height: 338)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                        .frame(width: 600, height: 338)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("PREVIEW")
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.22), in: Capsule())
                            Text("MUTED")
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.22), in: Capsule())
                        }
                        Text(item.name)
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
                .frame(width: 600, height: 338)
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 14)
    }
}

// MARK: - Hover preview player (muted VLC)

// Lightweight VLC player for the guide's hover preview. Audio is disabled
// entirely (--no-audio) so browsing the guide never makes sound. One
// instance only; in-flight loads are cancelled by the guide's debounced
// preview task when focus moves.
final class TVPreviewPlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show", "--no-audio"])
    @Published var playing = false
    @Published var failed = false
    private var timer: Timer?

    func attach(_ view: UIView) { engine.drawable = view }

    func play(url: URL) {
        failed = false
        playing = false
        engine.stop()
        guard let media = VLCMedia(url: url) else { failed = true; return }
        media.addOptions(["network-caching": 1500])
        engine.media = media
        engine.play()
        timer?.invalidate()
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.engine.state == .error {
                self.fail()
            } else if self.engine.isPlaying {
                self.playing = true
            } else if Date().timeIntervalSince(started) > 20 {
                self.fail()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        playing = false
        engine.stop()
    }

    private func fail() {
        timer?.invalidate()
        timer = nil
        failed = true
        engine.stop()
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
