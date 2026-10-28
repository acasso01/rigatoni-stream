import SwiftUI
import UIKit
import VLCKit

// Multi View: two live channels playing at once, side by side.
// The focused pane carries the sound (volume 100); the other pane stays
// muted (volume 0). Focus a pane to hear it. Select a pane to pick its
// channel. Up/Down on a focused pane steps through channels. Hold Select
// on a pane for the fullscreen option. Expanding a pane stops both panes
// first so only the fullscreen player has audio, and resumes them when
// the fullscreen player closes.
struct TVMultiView: View {
    @EnvironmentObject private var model: AppModel
    @State private var store: TVLibraryStore?
    @State private var paneA: CatalogItem?
    @State private var paneB: CatalogItem?
    @State private var activePane = 0
    @State private var suspended = false
    @State private var pickerPane = 0
    @State private var pickerOpen = false
    @State private var expanded: CatalogItem?
    @State private var retry = 0
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500

    private var channels: [CatalogItem] {
        guard let store else { return [] }
        return store.items.filter(model.preferences.visible)
    }

    var body: some View {
        Group {
            if let store {
                TVObservedStore(store: store) { content($0) }.id(ObjectIdentifier(store))
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(TVTheme.background)
        .onAppear {
            if store == nil { store = TVLibraryStore(kind: .live, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ store: TVLibraryStore) -> some View {
        if !model.providerReady {
            Text("Save your provider in Settings to watch.")
                .foregroundStyle(TVTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 32) {
                    Text("Multi View")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(TVTheme.text)
                    Text("Focus a screen to hear it. Select a screen to change its channel. Up and Down switch channels.")
                        .font(.system(size: 24))
                        .foregroundStyle(TVTheme.muted)
                        .lineLimit(2)
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)

                HStack(spacing: 24) {
                    TVMultiPane(
                        item: paneA, isActive: activePane == 0, suspended: suspended, cache: liveBuffer,
                        onFocused: { activePane = 0 },
                        onSelect: { pickerPane = 0; pickerOpen = true },
                        onStep: { stepPane(0, $0) },
                        onExpand: { expandPane(0) }
                    )
                    TVMultiPane(
                        item: paneB, isActive: activePane == 1, suspended: suspended, cache: liveBuffer,
                        onFocused: { activePane = 1 },
                        onSelect: { pickerPane = 1; pickerOpen = true },
                        onStep: { stepPane(1, $0) },
                        onExpand: { expandPane(1) }
                    )
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
            .task(id: "\(model.libraryRevision)-\(retry)") {
                await store.loadCategories()
                guard !Task.isCancelled else { return }
                await store.loadAllItems()
                guard !Task.isCancelled else { return }
                if paneA == nil { paneA = channels.first }
                if paneB == nil { paneB = channels.dropFirst().first }
            }
            .fullScreenCover(isPresented: $pickerOpen) {
                TVChannelPickerView(channels: channels, categories: store.categories) { channel in
                    pickChannel(channel, for: pickerPane)
                }
            }
            .fullScreenCover(item: $expanded, onDismiss: { suspended = false }) { item in
                CatalogDestination(item: item, channels: channels)
            }
        }
    }

    private func stepPane(_ index: Int, _ offset: Int) {
        let list = channels
        let current = index == 0 ? paneA : paneB
        guard let current, let at = list.firstIndex(where: { $0.scopedID == current.scopedID }) else { return }
        let next = at + offset
        guard list.indices.contains(next) else { return }
        if index == 0 { paneA = list[next] } else { paneB = list[next] }
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
private struct TVMultiPane: View {
    let item: CatalogItem?
    let isActive: Bool
    let suspended: Bool
    let cache: Int
    var onFocused: () -> Void
    var onSelect: () -> Void
    var onStep: (Int) -> Void
    var onExpand: () -> Void

    @EnvironmentObject private var model: AppModel
    @StateObject private var player = TVNativePlayer()
    @Environment(\.isFocused) private var focused

    private var url: URL? {
        guard let item else { return nil }
        return item.playbackURL ?? (try? model.provider(for: item).streamURL(item: item))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item, let url {
                TVMultiSurface(player: player, url: url, cache: cache)
            } else {
                Color.black
                VStack(spacing: 16) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 56))
                    Text("No channel")
                        .font(.system(size: 30, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(item?.name ?? "No channel")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                    if item != nil {
                        Text("LIVE")
                            .font(.system(size: 20, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Color.red, in: Capsule())
                            .accessibilityHidden(true)
                    }
                    if isActive, item != nil {
                        Text("SOUND ON")
                            .font(.system(size: 20, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.25), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
                if item != nil, player.state != "Playing" {
                    Text(player.state)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("Select: choose channel · Up/Down: change channel · Hold Select: fullscreen")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.black.opacity(0.65), .clear],
                               startPoint: .bottom, endPoint: .top)
            )
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(isActive ? 1.0 : (focused ? 0.6 : 0.15)),
                        lineWidth: isActive ? 5 : 2)
        )
        .focusable()
        .onTapGesture { onSelect() }
        .onMoveCommand { direction in
            if direction == .up { onStep(-1) }
            else if direction == .down { onStep(1) }
        }
        .onPlayPauseCommand { player.toggle() }
        .contextMenu {
            Button("Watch fullscreen") { onExpand() }
            Button("Change channel") { onSelect() }
        }
        .onChange(of: focused) { _, value in if value { onFocused() } }
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
        player.play(url: url, cache: cache)
    }
}

// Plain UIView as the VLC drawable for one multi-view pane. Playback
// starts in makeUIView, mirroring TVVideoSurface; later channel changes
// go through the pane's playCurrent().
private struct TVMultiSurface: UIViewRepresentable {
    let player: TVNativePlayer
    let url: URL
    let cache: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.attach(view)
        player.isLive = true
        player.play(url: url, cache: cache)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.attach(uiView)
    }
}

// Channel picker for one pane: every live channel, grouped by category.
private struct TVChannelPickerView: View {
    let channels: [CatalogItem]
    let categories: [CatalogCategory]
    var onPick: (CatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Choose a channel")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(TVTheme.text)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(TVCompactButtonStyle())
                }
                .padding(.horizontal, 60)
                .padding(.top, 48)

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
                                            .font(.system(size: 30))
                                        Spacer()
                                        if !channel.number.isEmpty {
                                            Text(channel.number)
                                                .font(.system(size: 26))
                                                .foregroundStyle(TVTheme.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(TVTheme.text)
        .onExitCommand { dismiss() }
    }

    private struct PickerSection: Identifiable {
        let id: String
        let title: String
        let items: [CatalogItem]
    }

    private var sections: [PickerSection] {
        var out: [PickerSection] = []
        for category in categories {
            let items = channels.filter { $0.categoryID == category.id }
            if !items.isEmpty {
                out.append(PickerSection(id: category.id, title: category.name, items: items))
            }
        }
        let rest = channels.filter { item in
            !categories.contains { $0.id == item.categoryID }
        }
        if !rest.isEmpty {
            out.append(PickerSection(id: "other", title: "Other", items: rest))
        }
        return out
    }
}
