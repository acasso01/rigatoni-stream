import SwiftUI
import UIKit
import VLCKit

// tvOS playback engine. Mirrors the iPhone build's NativePlayer semantics
// (VLC media, network-caching option, 0.5 s polling, state strings) minus
// the iOS-only pieces: no Picture in Picture, no lock-screen / remote
// commands, no AVAudioSession tweaks — tvOS manages audio focus itself.
@MainActor
final class TVNativePlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show"])
    @Published var state = "Connecting…"
    @Published var playing = false
    @Published var seekable = false
    @Published var position = 0.0
    @Published var elapsed = "0:00"
    @Published var resolution = ""
    var title = ""
    var isLive = false
    private var timer: Timer?
    private var openedAt = Date()
    private var url: URL?
    private var cache = 1500

    func attach(_ view: UIView) { engine.drawable = view }

    func play(url: URL, cache: Int) {
        self.url = url; self.cache = cache
        start()
    }

    func start() {
        guard let url else { return }
        engine.stop()
        playing = false; seekable = false; position = 0; elapsed = "0:00"
        resolution = ""; state = "Connecting…"
        guard let media = VLCMedia(url: url) else {
            state = "The stream URL could not be opened."
            return
        }
        media.addOptions(["network-caching": cache])
        engine.media = media; openedAt = Date(); engine.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    func poll() {
        playing = engine.isPlaying; seekable = engine.isSeekable
        position = Double(engine.position).clamped(to: 0...1)
        let seconds = max(0, Int(engine.time.value?.int64Value ?? 0) / 1000)
        elapsed = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let size = engine.videoSize
        resolution = size.width > 0 ? "\(Int(size.width))×\(Int(size.height)) · Original quality" : ""
        switch engine.state {
        case .playing: state = "Playing"
        case .paused: state = "Paused"
        case .error: state = "The stream could not play. Try another title or check the provider connection."
        case .stopped: state = "Playback stopped"
        default: state = Date().timeIntervalSince(openedAt) > 30
            ? "Still waiting for video. Retry or try another title." : "Connecting…"
        }
    }

    func toggle() { if engine.isPlaying { engine.pause() } else { engine.play() } }

    func seek(to value: Double) {
        if engine.isSeekable { engine.position = Float32(value) }
    }

    func stop() { timer?.invalidate(); timer = nil; engine.stop() }
}

// tvOS-local equivalent of the iPhone build's ChannelNavigation helper,
// which lives in the iOS-only Player.swift and is not shared.
private enum TVChannelNavigation {
    static func adjacent(in channels: [CatalogItem], currentID: String, offset: Int) -> CatalogItem? {
        guard let current = channels.firstIndex(where: { $0.id == currentID && $0.kind == .live }) else { return nil }
        let next = current + offset
        guard channels.indices.contains(next), channels[next].kind == .live else { return nil }
        return channels[next]
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// Plain UIView as the VLC drawable. tvOS needs no PiP bridge.
private struct TVVideoSurface: UIViewRepresentable {
    let player: TVNativePlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// Full-screen tvOS player.
// Siri Remote: press Play/Pause to toggle playback, Menu to go back.
// Overlay controls auto-hide after 4 seconds like the iPhone build.
struct TVPlayerView: View {
    let item: CatalogItem
    let provider: Provider
    var channels: [CatalogItem] = []
    /// Override for last-watched recording (e.g. "series" for TV show
    /// episodes, whose CatalogItem kind is .movies). Nil records the
    /// item's own kind.
    var lastWatchedKind: String? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = TVNativePlayer()
    @State private var currentID: String
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var seeking = false
    @FocusState private var focusPlay: Bool
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000

    init(item: CatalogItem, provider: Provider, channels: [CatalogItem] = [], lastWatchedKind: String? = nil) {
        self.item = item
        self.provider = provider
        self.channels = channels
        self.lastWatchedKind = lastWatchedKind
        _currentID = State(initialValue: item.id)
    }

    private var currentItem: CatalogItem {
        channels.first { $0.id == currentID } ?? item
    }

    private var playbackURL: URL? {
        currentItem.playbackURL
            ?? (provider.requiresGateway ? nil : try? provider.streamURL(item: currentItem))
    }

    private var cache: Int { currentItem.kind == .live ? liveBuffer : movieBuffer }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = playbackURL {
                TVVideoSurface(player: player)
                    .ignoresSafeArea()
            } else {
                Text("Invalid provider settings.").foregroundStyle(.white)
            }

            if controlsVisible {
                VStack {
                    HStack(spacing: 24) {
                        Button { player.stop(); dismiss() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        Text(currentItem.name)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { player.start(); showControls() }
                    }
                    .padding(40)
                    .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                               startPoint: .top, endPoint: .bottom))

                    Spacer()

                    HStack(spacing: 60) {
                        if currentItem.kind == .live {
                            Button { changeChannel(-1) } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .disabled(adjacentChannel(-1) == nil)
                            .accessibilityLabel("Previous channel")
                        }
                        Button { player.toggle(); showControls() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        }
                        .focused($focusPlay)
                        .accessibilityLabel(player.playing ? "Pause" : "Play")
                        if currentItem.kind == .live {
                            Button { changeChannel(1) } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .disabled(adjacentChannel(1) == nil)
                            .accessibilityLabel("Next channel")
                        }
                    }
                    .font(.system(size: 44, weight: .semibold))

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 20) {
                            Text(player.elapsed).monospacedDigit()
                            Spacer()
                            if !player.resolution.isEmpty {
                                Text(player.resolution).font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        if currentItem.kind == .movies && player.seekable {
                            Slider(value: $player.position, in: 0...1, onEditingChanged: { editing in
                                seeking = editing
                                if editing { hideTask?.cancel() }
                                else { player.seek(to: player.position); showControls() }
                            })
                            .accessibilityLabel("Movie position")
                        }
                        if player.state != "Playing" {
                            Text(player.state).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.bottom, 40)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                               startPoint: .top, endPoint: .bottom))
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .onPlayPauseCommand {
            player.toggle()
            showControls()
        }
        // Siri Remote left/right arrows switch live channels, following the
        // loaded channel list (same prev/next semantics as the on-screen
        // buttons). Up/down are left to the default focus behavior.
        .onMoveCommand { direction in
            guard currentItem.kind == .live, !channels.isEmpty else { return }
            switch direction {
            case .left: changeChannel(-1)
            case .right: changeChannel(1)
            default: break
            }
        }
        .onAppear {
            player.title = currentItem.name
            player.isLive = currentItem.kind == .live
            if let url = playbackURL { player.play(url: url, cache: cache) }
            showControls()
            TVLastWatched.record(
                kind: lastWatchedKind ?? (currentItem.kind == .live ? "live" : "movie"),
                item: currentItem,
                provider: provider
            )
        }
        .onChange(of: currentID) { _, _ in
            guard let url = playbackURL else { player.stop(); return }
            player.title = currentItem.name
            player.isLive = currentItem.kind == .live
            player.play(url: url, cache: cache)
            showControls()
            TVLastWatched.record(
                kind: lastWatchedKind ?? (currentItem.kind == .live ? "live" : "movie"),
                item: currentItem,
                provider: provider
            )
        }
        .onDisappear { hideTask?.cancel(); player.stop() }
        .onChange(of: player.playing) { _, playing in
            if playing { if controlsVisible { showControls() } }
            else { hideTask?.cancel(); controlsVisible = true }
        }
    }

    private func adjacentChannel(_ offset: Int) -> CatalogItem? {
        TVChannelNavigation.adjacent(in: channels, currentID: currentItem.id, offset: offset)
    }

    private func changeChannel(_ offset: Int) {
        guard let next = adjacentChannel(offset) else { return }
        hideTask?.cancel(); controlsVisible = true; seeking = false
        currentID = next.id
    }

    private func showControls() {
        controlsVisible = true
        focusPlay = true
        hideTask?.cancel()
        guard player.playing, !seeking else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.playing, !seeking else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }
}
