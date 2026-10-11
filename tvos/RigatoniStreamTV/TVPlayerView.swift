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
    var progressRecorder: ((Double, Double) -> Void)?
    var resumeSeconds = 0.0
    private var lastRecorded = Date.distantPast
    private var lastSeconds = 0.0
    private var lastDuration = 0.0
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
        if !isLive { resumeSeconds = max(resumeSeconds, lastSeconds) }
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
        let duration = Double(engine.media?.length.value?.int64Value ?? 0) / 1000
        if !isLive, resumeSeconds > 0, seekable, duration > resumeSeconds {
            engine.position = min(1, resumeSeconds / duration); resumeSeconds = 0
        } else if !isLive, resumeSeconds == 0, duration > 0, seconds > 0 {
            lastSeconds = Double(seconds); lastDuration = duration
            if Date().timeIntervalSince(lastRecorded) >= 5 {
                progressRecorder?(lastSeconds, lastDuration); lastRecorded = Date()
            }
        }
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
        if engine.isSeekable { engine.position = value }
    }

    func skip(seconds: Double) {
        guard engine.isSeekable, let length = engine.media?.length.value?.doubleValue, length > 0 else { return }
        seek(to: (Double(engine.position) + seconds * 1000 / length).clamped(to: 0...1))
    }

    func stop() {
        if !isLive, resumeSeconds == 0 { progressRecorder?(lastSeconds, lastDuration) }
        timer?.invalidate(); timer = nil; engine.stop()
    }
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
    var startSeconds: Double = 0
    var lastWatchedKind: String? = nil
    var progressID: String? = nil
    @EnvironmentObject private var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = TVNativePlayer()
    @State private var currentID: String
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var seeking = false
    @FocusState private var focusPlay: Bool
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000

    init(item: CatalogItem, provider: Provider, channels: [CatalogItem] = [], startSeconds: Double = 0, lastWatchedKind: String? = nil, progressID: String? = nil) {
        self.item = item
        self.provider = provider
        self.channels = channels
        self.startSeconds = startSeconds
        self.lastWatchedKind = lastWatchedKind
        self.progressID = progressID
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
                            HStack(spacing: 32) {
                                Button("Back 10 seconds") { player.skip(seconds: -10); showControls() }
                                Button("Forward 10 seconds") { player.skip(seconds: 10); showControls() }
                            }
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
        .focusable(!controlsVisible)
        .onTapGesture { if !controlsVisible { showControls() } }
        .onMoveCommand { direction in
            if !controlsVisible, currentItem.kind == .live {
                if direction == .left { changeChannel(-1); return }
                if direction == .right { changeChannel(1); return }
            }
            if !controlsVisible { showControls() }
        }
        .onExitCommand {
            if controlsVisible { player.stop(); dismiss() }
            else { showControls() }
        }
        .onPlayPauseCommand {
            player.toggle()
            showControls()
        }
        .onAppear {
            player.resumeSeconds = startSeconds
            player.progressRecorder = { seconds, duration in model.saveProgress(id: progressID ?? item.id, seconds: seconds, duration: duration) }
            player.title = currentItem.name
            player.isLive = currentItem.kind == .live
            if let url = playbackURL { player.play(url: url, cache: cache) }
            recordHistory()
            showControls()
        }
        .onChange(of: currentID) { _, _ in
            guard let url = playbackURL else { player.stop(); return }
            player.resumeSeconds = startSeconds
            player.progressRecorder = { seconds, duration in model.saveProgress(id: progressID ?? item.id, seconds: seconds, duration: duration) }
            player.title = currentItem.name
            player.isLive = currentItem.kind == .live
            player.play(url: url, cache: cache)
            recordHistory()
            showControls()
        }
        .onDisappear { hideTask?.cancel(); player.stop() }
        .onChange(of: player.playing) { _, playing in
            if playing { if controlsVisible { showControls() } }
            else { hideTask?.cancel(); controlsVisible = true }
        }
    }

    private func recordHistory() {
        guard playbackURL != nil else { return }
        TVLastWatched.record(kind: lastWatchedKind ?? (currentItem.kind == .live ? "live" : "movie"), item: currentItem, model: model)
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
