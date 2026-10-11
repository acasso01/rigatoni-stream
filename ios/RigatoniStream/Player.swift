import SwiftUI
import AVFoundation
import VLCKit
import AVKit
import MediaPlayer

@MainActor
final class NativePlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show"])
    @Published var state = "Connecting…"
    @Published var playing = false
    @Published var seekable = false
    @Published var position: Double = 0
    @Published var elapsed = "0:00"
    @Published var resolution = ""
    @Published var pictureInPictureAvailable = false
    @Published var pictureInPictureActive = false
    private var pipBridge: PictureInPictureBridge?
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
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
    private var dragging = false
    func attach(_ view: UIView, url: URL, cache: Int) {
        let bridge = PictureInPictureBridge(view: view, player: engine)
        bridge.availabilityChanged = { [weak self] ready in
            self?.pictureInPictureAvailable = ready && AVPictureInPictureController.isPictureInPictureSupported()
        }
        bridge.activeChanged = { [weak self] active in self?.pictureInPictureActive = active }
        pipBridge = bridge
        engine.drawable = bridge
        installPlaybackControls()
        self.url = url; self.cache = cache
        start()
    }
    func changeSource(url: URL, cache: Int) {
        guard self.url != url || self.cache != cache else { return }
        self.url = url; self.cache = cache
        start()
    }
    func start() {
        guard let url else { return }
        engine.stop()
        playing = false; seekable = false; position = 0; elapsed = "0:00"; resolution = ""; state = "Connecting…"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let media = VLCMedia(url: url) else { state = "The stream URL could not be opened."; return }
        media.addOptions(["network-caching": cache])
        engine.media = media; openedAt = Date(); engine.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func poll() {
        playing = engine.isPlaying; seekable = engine.isSeekable
        if !dragging { position = Double(engine.position).clamped(to: 0...1) }
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
        elapsed = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let size = engine.videoSize
        resolution = size.width > 0 ? "\(Int(size.width))×\(Int(size.height)) · Original quality" : ""
        pipBridge?.invalidatePlaybackState()
        updateNowPlaying()
        switch engine.state {
        case .playing: state = "Playing"
        case .paused: state = "Paused"

        case .error: state = "The stream could not play. Try another title or check the provider connection."
        case .stopped: state = "Playback stopped"
        default: state = Date().timeIntervalSince(openedAt) > 30 ? "Still waiting for video. Retry or try another title." : "Connecting…"
        }
    }
    func toggle() { if engine.isPlaying { engine.pause() } else { engine.play() } }
    func seekEditing(_ value: Bool) {
        dragging = value
        if !value && engine.isSeekable { engine.position = position }
    }
    func startPictureInPicture() {
        guard pictureInPictureAvailable else { return }
        pipBridge?.startPictureInPicture()
    }
    private func installPlaybackControls() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.isPlaying else { return }
                self.startPictureInPicture()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.engine.pause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.engine.pause() }
            }
        })
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true; commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        remoteTargets = [
            (commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.engine.play() }; return .success
            }),
            (commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.engine.pause() }; return .success
            }),
            (commands.togglePlayPauseCommand, commands.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.toggle() }; return .success
            })
        ]
    }
    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(engine.time.value?.int64Value ?? 0) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        let duration = Double(engine.media?.length.value?.int64Value ?? 0) / 1000
        if !isLive && duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    func stop() {
        if !isLive, resumeSeconds == 0 { progressRecorder?(lastSeconds, lastDuration) }
        timer?.invalidate(); timer = nil
        pipBridge?.detach(); pipBridge = nil
        pictureInPictureAvailable = false; pictureInPictureActive = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        remoteTargets.forEach { $0.0.removeTarget($0.1) }; remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        engine.stop(); engine.media = nil; engine.drawable = nil; url = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, self)) }
}

enum VideoDisplayMode: String, CaseIterable {
    case fit = "Fit", fill = "Fill", zoom = "Zoom"
    var next: VideoDisplayMode { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    func frame(in bounds: CGRect, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = (self == .fit ? min(bounds.width / video.width, bounds.height / video.height) : max(bounds.width / video.width, bounds.height / video.height)) * (self == .zoom ? 1.25 : 1)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

final class VideoCanvas: UIView {
    var onTap: (() -> Void)?
    let drawable = UIView()
    let touchSurface = UIView()
    var mode = VideoDisplayMode.fit
    var videoSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true
        drawable.backgroundColor = .black
        addSubview(drawable)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        // Touches land here, never on VLC's internal video controls.
        touchSurface.backgroundColor = .clear
        addSubview(touchSurface)
        touchSurface.addGestureRecognizer(tap)
    }
    @objc func tapped() { onTap?() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        drawable.frame = mode.frame(in: bounds, video: videoSize)
        touchSurface.frame = bounds
        bringSubviewToFront(touchSurface)
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: NativePlayer
    let url: URL
    let cache: Int
    let mode: VideoDisplayMode
    let onTap: () -> Void
    func makeUIView(context: Context) -> VideoCanvas {
        let view = VideoCanvas()
        view.onTap = onTap
        player.attach(view.drawable, url: url, cache: cache)
        return view
    }
    func updateUIView(_ view: VideoCanvas, context: Context) {
        view.onTap = onTap
        view.mode = mode; view.videoSize = player.engine.videoSize
        view.setNeedsLayout()
    }
}

enum ChannelNavigation {
    static func adjacent(in channels: [CatalogItem], currentID: String, offset: Int) -> CatalogItem? {
        guard let current = channels.firstIndex(where: { $0.id == currentID && $0.kind == .live }) else { return nil }
        let next = current + offset
        guard channels.indices.contains(next), channels[next].kind == .live else { return nil }
        return channels[next]
    }
}

struct PlayerView: View {
    let item: CatalogItem
    let provider: Provider
    var channels: [CatalogItem] = []
    var startSeconds: Double = 0
    @EnvironmentObject private var model: AppModel
    @State private var selectedChannel: CatalogItem?
    private var currentItem: CatalogItem { selectedChannel ?? item }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = NativePlayer()
    @State private var controlsVisible = true
    @State private var displayMode = VideoDisplayMode.fit
    @State private var hideTask: Task<Void, Never>?
    @State private var seeking = false
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = currentItem.playbackURL ?? (provider.requiresGateway ? nil : try? provider.streamURL(item: currentItem)) {
                PlayerSurface(player: player, url: url, cache: currentItem.kind == .live ? liveBuffer : movieBuffer, mode: displayMode, onTap: showControls)
                    .ignoresSafeArea()
                    .accessibilityLabel("Video. Tap to show playback controls.")
            } else { Text("Invalid provider settings.") }
            if controlsVisible {
                HStack(spacing: 40) {
                    if currentItem.kind == .live {
                        Button { changeChannel(-1) } label: { Image(systemName: "backward.end.fill") }
                            .disabled(adjacentChannel(-1) == nil).accessibilityLabel("Previous channel")
                    }
                    Button { player.toggle(); showControls() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    }.accessibilityLabel(player.playing ? "Pause" : "Play")
                    if currentItem.kind == .live {
                        Button { changeChannel(1) } label: { Image(systemName: "forward.end.fill") }
                            .disabled(adjacentChannel(1) == nil).accessibilityLabel("Next channel")
                    }
                }
                .font(.system(size: 30, weight: .semibold))
                .buttonStyle(TransparentPlaybackButton()).tint(.white)
                VStack {
                    HStack(spacing: 12) {
                        Button { player.stop(); dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                        Text(currentItem.name).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { player.startPictureInPicture(); showControls() } label: {
                            Image(systemName: "pip").frame(minWidth: 44, minHeight: 44)
                        }.disabled(!player.pictureInPictureAvailable).accessibilityLabel("Picture in Picture")
                        Button { displayMode = displayMode.next; showControls() } label: {
                            Label(displayMode.rawValue, systemImage: displayMode == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        }.accessibilityLabel("Picture mode: \(displayMode.rawValue). Tap to change fit, fill or zoom.")
                    }
                    .padding().background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 10) {
                        HStack {
                            Button { player.toggle(); showControls() } label: {
                                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 44, height: 44)
                            }.accessibilityLabel(player.playing ? "Pause" : "Play")
                            Text(player.elapsed).monospacedDigit()
                            Spacer()
                            if !player.resolution.isEmpty { Text(player.resolution).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                            Button("Retry") { player.start(); showControls() }
                        }
                        if currentItem.kind == .movies && player.seekable {
                            Slider(value: $player.position, in: 0...1, onEditingChanged: { editing in
                                seeking = editing; player.seekEditing(editing)
                                if editing { hideTask?.cancel() } else { showControls() }
                            }).accessibilityLabel("Movie position")
                        }
                        if player.state != "Playing" && player.state != "Buffering…" {
                            Text(player.state).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal).padding(.bottom, 8).background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                }.foregroundStyle(.white).buttonStyle(TransparentPlaybackButton()).transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear { player.resumeSeconds = startSeconds; player.progressRecorder = { seconds, duration in model.saveProgress(id: item.id, seconds: seconds, duration: duration) }; player.title = currentItem.name; player.isLive = currentItem.kind == .live; showControls() }
        .onChange(of: currentItem.id) { _, _ in
            guard let url = currentItem.playbackURL ?? (provider.requiresGateway ? nil : try? provider.streamURL(item: currentItem)) else {
                player.stop(); return
            }
            player.title = currentItem.name; player.isLive = currentItem.kind == .live
            player.changeSource(url: url, cache: liveBuffer)
            showControls()
        }
        .onDisappear { hideTask?.cancel(); player.stop() }
        .onChange(of: player.playing) { _, playing in
            if playing { if controlsVisible { showControls() } }
            else { hideTask?.cancel(); controlsVisible = true }
        }
    }
    private func adjacentChannel(_ offset: Int) -> CatalogItem? {
        ChannelNavigation.adjacent(in: channels, currentID: currentItem.id, offset: offset)
    }
    private func changeChannel(_ offset: Int) {
        guard let next = adjacentChannel(offset) else { return }
        hideTask?.cancel(); controlsVisible = true; seeking = false
        selectedChannel = next
    }
    private func showControls() {
        controlsVisible = true; hideTask?.cancel()
        guard player.playing, !seeking else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.playing, !seeking else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }
}

struct TransparentPlaybackButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}
