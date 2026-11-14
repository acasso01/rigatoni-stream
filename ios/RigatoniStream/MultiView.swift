import SwiftUI
import VLCKit

// Multi View: two live channels at once. Side by side in landscape,
// stacked in portrait. Tapping a pane makes it the audible one; the
// other pane stays muted. Each pane has its own channel controls, and
// either pane can go fullscreen. Expanding a pane stops both panes
// first so only the fullscreen player has audio, and resumes them when
// the fullscreen player closes.
struct MultiPlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [CatalogItem] = []
    @State private var categories: [CatalogCategory] = []
    @State private var paneA: CatalogItem?
    @State private var paneB: CatalogItem?
    @State private var activePane = 0
    @State private var suspended = false
    @State private var pickerPane = 0
    @State private var pickerOpen = false
    @State private var expanded: CatalogItem?
    @State private var loading = false
    @State private var error = ""
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Close Multi View")
                Text("Multi View")
                    .font(.headline)
                Spacer()
                Text("Tap a screen for sound")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.black)

            ZStack {
                Color.black.ignoresSafeArea()
                if loading, channels.isEmpty {
                    ProgressView("Loading channels…")
                        .foregroundStyle(.white)
                } else if !error.isEmpty, channels.isEmpty {
                    VStack(spacing: 12) {
                        Text(error)
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    GeometryReader { geo in
                        if geo.size.width > geo.size.height {
                            HStack(spacing: 2) { pane(0); pane(1) }
                        } else {
                            VStack(spacing: 2) { pane(0); pane(1) }
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .task { await load() }
        .sheet(isPresented: $pickerOpen) {
            MultiChannelPicker(channels: channels, categories: categories) { channel in
                pickChannel(channel, for: pickerPane)
            }
        }
        .fullScreenCover(item: $expanded, onDismiss: { suspended = false }) { item in
            CatalogDestination(item: item, channels: channels)
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func pane(_ index: Int) -> some View {
        MultiPane(
            item: index == 0 ? paneA : paneB,
            channels: channels,
            isActive: activePane == index,
            suspended: suspended,
            cache: liveBuffer,
            onActivate: { activePane = index },
            onPick: { pickerPane = index; pickerOpen = true },
            onStep: { stepPane(index, $0) },
            onExpand: { expandPane(index) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard model.providerReady else { return }
        loading = true
        defer { loading = false }
        do {
            let cats = try await model.catalog.categories(kind: .live, model: model)
            try Task.checkCancellation()
            categories = cats
            let result = try await model.catalog.loadAll(kind: .live, model: model)
            try Task.checkCancellation()
            channels = result.items.filter(model.preferences.visible)
            error = result.notice
            if paneA == nil { paneA = channels.first }
            if paneB == nil { paneB = channels.dropFirst().first }
        } catch {
            if !Task.isCancelled { error = error.localizedDescription }
        }
    }

    private func stepPane(_ index: Int, _ offset: Int) {
        let current = index == 0 ? paneA : paneB
        guard let next = ChannelNavigation.adjacent(
            in: channels,
            currentID: current?.scopedID ?? "",
            offset: offset
        ) else { return }
        if index == 0 { paneA = next } else { paneB = next }
    }

    private func pickChannel(_ channel: CatalogItem, for pane: Int) {
        if pane == 0 { paneA = channel } else { paneB = channel }
        activePane = pane
    }

    private func expandPane(_ index: Int) {
        guard let item = index == 0 ? paneA : paneB else { return }
        suspended = true
        expanded = item
    }
}

// One pane of the multi view: its own VLC player, muted unless active.
private struct MultiPane: View {
    let item: CatalogItem?
    let channels: [CatalogItem]
    let isActive: Bool
    let suspended: Bool
    let cache: Int
    var onActivate: () -> Void
    var onPick: () -> Void
    var onStep: (Int) -> Void
    var onExpand: () -> Void

    @EnvironmentObject private var model: AppModel
    @StateObject private var player = NativePlayer()

    private var url: URL? {
        guard let item else { return nil }
        return item.playbackURL ?? (try? model.provider(for: item).streamURL(item: item))
    }

    private var canStep: (Int) -> Bool {
        { offset in
            ChannelNavigation.adjacent(
                in: channels,
                currentID: item?.scopedID ?? "",
                offset: offset
            ) != nil
        }
    }

    var body: some View {
        ZStack {
            if let item, let url {
                MultiPlayerSurface(player: player, url: url, cache: cache)
            } else {
                Color.black
                VStack(spacing: 10) {
                    Image(systemName: "tv.slash")
                        .font(.largeTitle)
                    Text("No channel")
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if item != nil, player.state != "Playing" {
                Text(player.state)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }

            VStack {
                HStack(spacing: 8) {
                    Text(item?.name ?? "No channel")
                        .font(.headline)
                        .lineLimit(1)
                    if item != nil {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.white)
                            .background(Color.red, in: Capsule())
                            .accessibilityHidden(true)
                    }
                    if isActive, item != nil {
                        Text("SOUND ON")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.25), in: Capsule())
                            .accessibilityHidden(true)
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )

                Spacer()

                HStack(spacing: 20) {
                    Button { onStep(-1) } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!canStep(-1))
                    .accessibilityLabel("Previous channel")
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(player.playing ? "Pause" : "Play")
                    Button { onStep(1) } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!canStep(1))
                    .accessibilityLabel("Next channel")
                    Spacer()
                    Button("Channels") { onPick() }
                        .accessibilityLabel("Choose a channel for this screen")
                    Button { onExpand() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(item == nil)
                    .accessibilityLabel("Watch fullscreen")
                }
                .font(.system(size: 20, weight: .semibold))
                .buttonStyle(TransparentPlaybackButton())
                .padding(10)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isActive ? 1.0 : 0.2), lineWidth: isActive ? 3 : 1)
        )
        .onTapGesture { onActivate() }
        .onChange(of: isActive) { _, _ in applyVolume() }
        .onChange(of: item?.scopedID) { _, _ in playCurrent() }
        .onChange(of: suspended) { _, value in
            if value { player.stop() } else { playCurrent() }
        }
        .onAppear { applyVolume() }
        .onDisappear { player.stop() }
    }

    // Volume 0 silences the pane; 100 is normal volume.
    private func applyVolume() {
        player.engine.audio?.volume = isActive ? 100 : 0
    }

    private func playCurrent() {
        guard !suspended, let item, let url else {
            player.stop()
            return
        }
        player.title = item.name
        player.isLive = true
        player.changeSource(url: url, cache: cache)
    }
}

// Plain UIView as the VLC drawable for one multi-view pane. No PiP
// bridge: the pane uses the player's plain attach, and playback starts
// in makeUIView; later channel changes go through playCurrent().
private struct MultiPlayerSurface: UIViewRepresentable {
    let player: NativePlayer
    let url: URL
    let cache: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.attachPlain(view, url: url, cache: cache)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.engine.drawable = uiView
    }
}

// Channel picker for one pane: every live channel, searchable and
// grouped by category.
private struct MultiChannelPicker: View {
    let channels: [CatalogItem]
    let categories: [CatalogCategory]
    var onPick: (CatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [CatalogItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items, id: \.scopedID) { channel in
                            Button {
                                onPick(channel)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(channel.name)
                                    Spacer()
                                    if !channel.number.isEmpty {
                                        Text(channel.number)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search channels")
            .navigationTitle("Choose a channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private struct PickerSection: Identifiable {
        let id: String
        let title: String
        let items: [CatalogItem]
    }

    private var sections: [PickerSection] {
        var out: [PickerSection] = []
        for category in categories {
            let items = filtered.filter { $0.categoryID == category.id }
            if !items.isEmpty {
                out.append(PickerSection(id: category.id, title: category.name, items: items))
            }
        }
        let rest = filtered.filter { item in
            !categories.contains { $0.id == item.categoryID }
        }
        if !rest.isEmpty {
            out.append(PickerSection(id: "other", title: "Other", items: rest))
        }
        return out
    }
}
