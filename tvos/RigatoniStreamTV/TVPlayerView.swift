import SwiftUI
import UIKit
import VLCKit

// tvOS playback engine. Mirrors the iPhone build's NativePlayer semantics
// (VLC media, network-caching option, 0.5 s polling, state strings) minus
// the iOS-only pieces: no Picture in Picture, no lock-screen / remote
// commands, no AVAudioSession tweaks — tvOS manages audio focus itself.
@MainActor
final class TVNativePlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ProviderHTTP.playerArguments())
    @Published var state = "Connecting…"
    @Published var playing = false
    @Published var seekable = false
    @Published var position = 0.0
    @Published var duration = 0.0
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
        resetShuttle()
        playing = false; seekable = false; position = 0; elapsed = "0:00"
        resolution = ""; state = "Connecting…"
        guard let media = VLCMedia(url: url) else {
            state = "The stream URL could not be opened on \(ProviderHTTP.endpoint(url))."
            return
        }
        media.addOptions(ProviderHTTP.mediaOptions(cache: cache))
        engine.media = media; openedAt = Date(); engine.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    func poll() {
        seekable = engine.isSeekable
        let duration = Double(engine.media?.length.value?.int64Value ?? 0) / 1000
        self.duration = max(0, duration)
        let currentSeconds = playbackSeconds
        if shuttleDirection == -1, seekable, duration > 0 {
            // Negative VLC rates are not supported by every demuxer. Seek
            // against a monotonic clock while paused instead of requesting one.
            engine.position = (currentSeconds / duration).clamped(to: 0...1)
            if currentSeconds <= 0 { resetShuttle(); engine.pause() }
        }
        playing = engine.isPlaying || shuttleSpeed > 0
        position = shuttleDirection == -1 && duration > 0
            ? (currentSeconds / duration).clamped(to: 0...1)
            : Double(engine.position).clamped(to: 0...1)
        let seconds = max(0, Int(currentSeconds))
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
        if shuttleSpeed > 0 {
            state = "\(shuttleDirection == -1 ? "Rewinding" : "Forward") \(shuttleRate)×"
            return
        }
        switch engine.state {
        case .playing: state = "Playing"
        case .paused: state = "Paused"
        case .error:
            let host = self.url.map(ProviderHTTP.endpoint) ?? "the provider"
            state = "The stream could not play from \(host). Ant Streams opened that host directly; no gateway was used."
        case .stopped: state = "Playback stopped"
        default: state = Date().timeIntervalSince(openedAt) > 30
            ? "Still waiting for video. Retry or try another title." : "Connecting…"
        }
    }

    func toggle() {
        if shuttleSpeed > 0 {
            resumeNormalPlayback()
        } else if playing {
            engine.pause()
            playing = false
        } else {
            engine.play()
            playing = true
        }
    }

    @Published var shuttleSpeed = 0
    @Published var shuttleDirection = 0

    private var reverseAnchorSeconds = 0.0
    private var reverseStartedAt = 0.0
    private var playbackSeconds: Double {
        if shuttleDirection == -1 {
            return max(0, reverseAnchorSeconds - (ProcessInfo.processInfo.systemUptime - reverseStartedAt) * Double(shuttleRate))
        }
        return max(0, Double(engine.time.value?.int64Value ?? 0) / 1000)
    }

    private let shuttleSpeeds: [Float] = [1, 2, 4, 8, 32, 50]
    var shuttleRate: Int { shuttleSpeed == 0 ? 1 : Int(shuttleSpeeds[shuttleSpeed - 1]) }

    private func resetShuttle() {
        shuttleSpeed = 0
        shuttleDirection = 0
        engine.rate = 1
    }

    func shuttle(_ direction: Int) {
        guard !isLive, engine.isSeekable, direction == -1 || direction == 1 else { return }

        let anchor = playbackSeconds
        if shuttleDirection == direction {
            shuttleSpeed = (shuttleSpeed % shuttleSpeeds.count) + 1
        } else {
            shuttleDirection = direction
            shuttleSpeed = 1
        }

        let speed = shuttleSpeeds[shuttleSpeed - 1]
        playing = true
        if direction > 0 {
            engine.play()
            engine.fastForward(atRate: speed)
        } else {
            engine.rate = 1
            engine.pause()
            reverseAnchorSeconds = anchor
            reverseStartedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    func resumeNormalPlayback() {
        resetShuttle()
        playing = true

        if !engine.isPlaying {
            engine.play()
        }
    }

    func pauseForScrubbing() {
        if shuttleDirection == -1 { seek(to: duration > 0 ? playbackSeconds / duration : position) }
        resetShuttle()
        engine.pause()
        playing = false
    }

    func seek(to value: Double) {
        guard engine.isSeekable else { return }
        resumeSeconds = 0
        position = value.clamped(to: 0...1)
        engine.position = position
    }

    func skip(seconds: Double) {
        guard engine.isSeekable, let length = engine.media?.length.value?.doubleValue, length > 0 else { return }
        seek(to: (Double(engine.position) + seconds * 1000 / length).clamped(to: 0...1))
    }

    func stop() {
        // Back and onDisappear can both stop the same playback session.
        guard timer != nil else { return }
        // Capture the current position, including a seek since the last poll.
        if !isLive, resumeSeconds == 0 {
            let seconds = playbackSeconds
            let duration = Double(engine.media?.length.value?.int64Value ?? 0) / 1000
            if duration > 0 { lastSeconds = max(0, seconds); lastDuration = duration }
            progressRecorder?(lastSeconds, lastDuration)
        }
        timer?.invalidate(); timer = nil; engine.stop()
        resetShuttle()
        playing = false
    }
}

// tvOS-local equivalent of the iPhone build's ChannelNavigation helper,
// which lives in the iOS-only Player.swift and is not shared.
private enum TVChannelNavigation {
    static func adjacent(in channels: [CatalogItem], currentID: String, offset: Int) -> CatalogItem? {
        guard let current = channels.firstIndex(where: { $0.scopedID == currentID && $0.kind == .live }) else { return nil }
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

    func updateUIView(_ uiView: UIView, context: Context) {
        player.attach(uiView)
    }
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
    private enum Control: Hashable { case surface, back, retry, play, previous, next }
    @FocusState private var focusedControl: Control?
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000

    init(item: CatalogItem, provider: Provider, channels: [CatalogItem] = [], startSeconds: Double = 0, lastWatchedKind: String? = nil, progressID: String? = nil) {
        self.item = item
        self.provider = provider
        self.channels = channels
        self.startSeconds = startSeconds
        self.lastWatchedKind = lastWatchedKind
        self.progressID = progressID
        _currentID = State(initialValue: item.scopedID)
    }

    private var currentItem: CatalogItem {
        channels.first { $0.scopedID == currentID } ?? item
    }

    private var owner: Provider { model.provider(for: currentItem) }

    private var playbackURL: URL? {
        currentItem.playbackURL
            ?? (try? owner.streamURL(item: currentItem))
    }

    private var cache: Int { currentItem.kind == .live ? liveBuffer : movieBuffer }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = playbackURL {
                TVVideoSurface(player: player)
                    .task(id: currentID) {
                        player.isLive = currentItem.kind == .live
                        player.resumeSeconds = currentItem.kind == .live ? 0 : startSeconds
                        player.play(url: url, cache: cache)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else {
                Text("Could not open this provider stream. Check the provider address and try again.")
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }

            // This focus target exists only while the buttons are hidden. It
            // never wraps buttons or competes with their Select/move events.
            if !controlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focusedControl, equals: .surface)
                    .onTapGesture { showControls() }
                    .onMoveCommand { direction in
                        if currentItem.kind == .live, direction == .left { changeChannel(-1) }
                        else if currentItem.kind == .live, direction == .right { changeChannel(1) }
                        else { showControls() }
                    }
            }

            if controlsVisible {
                VStack {
                    HStack(spacing: 24) {
                        Button { player.stop(); dismiss() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .focused($focusedControl, equals: .back)
                        .accessibilityLabel("Back")
                        Text(currentItem.name)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { player.start(); showControls() }
                            .focused($focusedControl, equals: .retry)
                    }
                    .focusSection()
                    .padding(40)
                    .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                               startPoint: .top, endPoint: .bottom))

                    Spacer()

                    HStack(spacing: 60) {
                        if currentItem.kind == .live {
                            Button { changeChannel(-1) } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .focused($focusedControl, equals: .previous)
                            .disabled(adjacentChannel(-1) == nil)
                            .accessibilityLabel("Previous channel")
                        }
                        Button { player.toggle(); showControls() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        }
                        .focused($focusedControl, equals: .play)
                        .accessibilityLabel(player.playing ? "Pause" : "Play")
                        if currentItem.kind == .live {
                            Button { changeChannel(1) } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .focused($focusedControl, equals: .next)
                            .disabled(adjacentChannel(1) == nil)
                            .accessibilityLabel("Next channel")
                        }
                    }
                    .font(.system(size: 44, weight: .semibold))
                    .focusSection()

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 20) {
                            Text(player.elapsed).monospacedDigit()
                            Spacer()
                            if !player.resolution.isEmpty {
                                Text(player.resolution).font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                        }

                        if currentItem.kind != .live, player.seekable, player.duration > 0 {
                            TVMovieTimeline(position: player.position, duration: player.duration,
                                            shuttleStatus: player.shuttleSpeed > 0 ? player.state : "",
                                            onFocus: { player.pauseForScrubbing(); showControls() },
                                            onSeek: { player.pauseForScrubbing(); player.seek(to: $0) },
                                            onShuttle: { player.shuttle($0); showControls() },
                                            onPlay: { player.resumeNormalPlayback(); focusTimelineExit() })
                                .frame(height: 100)
                                .focusSection()
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
        .task(id: controlsVisible) {
            // Wait until the newly inserted focus target is in the hierarchy.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedControl = controlsVisible ? .play : .surface
        }
        .onChange(of: focusedControl) { _, control in
            if controlsVisible, control != nil { scheduleHide() }
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
            player.progressRecorder = { seconds, duration in model.saveProgress(id: progressID ?? item.id, seconds: seconds, duration: duration) }
            player.title = currentItem.name
            recordHistory()
            showControls()
        }
        .onChange(of: currentID) { _, _ in
            guard playbackURL != nil else { player.stop(); return }
            player.title = currentItem.name
            recordHistory()
            showControls()
        }
        .onDisappear { hideTask?.cancel(); player.stop() }
        .onChange(of: player.playing) { _, playing in
            if playing { if controlsVisible { showControls() } }
            else { showControls() }
        }
    }

    private func focusTimelineExit() {
        focusedControl = nil
        Task { @MainActor in
            await Task.yield()
            focusedControl = .play
        }
        showControls()
    }

    private func recordHistory() {
        guard playbackURL != nil else { return }
        TVLastWatched.record(kind: lastWatchedKind ?? (currentItem.kind == .live ? "live" : "movie"), item: currentItem, model: model)
    }

    private func adjacentChannel(_ offset: Int) -> CatalogItem? {
        TVChannelNavigation.adjacent(in: channels, currentID: currentItem.scopedID, offset: offset)
    }

    private func changeChannel(_ offset: Int) {
        guard let next = adjacentChannel(offset) else { return }
        hideTask?.cancel(); showControls()
        currentID = next.scopedID
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Keep controls available while paused, connecting, or shuttling.
        guard controlsVisible, player.playing, player.shuttleSpeed == 0 else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.playing, player.shuttleSpeed == 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }
}

// UIKit pan gestures support the Siri Remote touch surface on tvOS.
// Keep them on the timeline itself so transport buttons retain their events.
private struct TVMovieTimeline: UIViewRepresentable {
    let position: Double
    let duration: Double
    let shuttleStatus: String
    let onFocus: () -> Void
    let onSeek: (Double) -> Void
    let onShuttle: (Int) -> Void
    let onPlay: () -> Void

    func makeUIView(context: Context) -> TVMovieTimelineControl { TVMovieTimelineControl() }

    func updateUIView(_ view: TVMovieTimelineControl, context: Context) {
        view.position = position
        view.duration = duration
        view.shuttleStatus = shuttleStatus
        view.onShuttle = onShuttle
        view.onFocus = onFocus
        view.onSeek = onSeek
        view.onPlay = onPlay
        view.setNeedsLayout()
    }
}

private final class TVMovieTimelineControl: UIView, UIGestureRecognizerDelegate {
    var position = 0.0
    var duration = 0.0
    var shuttleStatus = ""
    var onShuttle: ((Int) -> Void)?
    var onFocus: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onPlay: (() -> Void)?
    private var panStart = 0.0
    private let track = UIView()
    private let fill = UIView()
    private let thumb = UIView()
    private let timeLabel = UILabel()
    private let hint = UILabel()
    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "movie-timeline"
        accessibilityLabel = "Movie timeline"
        accessibilityTraits = [.adjustable]
        for view in [track, fill, thumb, timeLabel, hint] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        track.backgroundColor = .white.withAlphaComponent(0.3)
        track.layer.cornerRadius = 4
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 4
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 9
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        timeLabel.textColor = .white
        hint.font = .systemFont(ofSize: 20)
        hint.textColor = .white.withAlphaComponent(0.8)
        hint.textAlignment = .right
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrub(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)
        for type in [UIPress.PressType.leftArrow, .rightArrow, .select] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(press(_:)))
            tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
            addGestureRecognizer(tap)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - 20)
        let progress = CGFloat(position.clamped(to: 0...1))
        track.frame = CGRect(x: 10, y: 30, width: width, height: 8)
        fill.frame = CGRect(x: 10, y: 30, width: width * progress, height: 8)
        thumb.frame = CGRect(x: 1 + width * progress, y: 25, width: 18, height: 18)
        thumb.isHidden = !isFocused
        fill.backgroundColor = isFocused ? .systemCyan : .white
        timeLabel.frame = CGRect(x: 10, y: 55, width: width * 0.45, height: 30)
        hint.frame = CGRect(x: width * 0.45, y: 55, width: width * 0.55, height: 30)
        timeLabel.text = "\(clock(position * duration)) / \(clock(duration))"
        hint.text = isFocused
            ? (shuttleStatus.isEmpty ? "Drag to seek · ← → Speed · Click to play" : "\(shuttleStatus) · Click to play")
            : "↓ Timeline · Pause and scrub"
        accessibilityValue = timeLabel.text
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsLayout()
        if isFocused { onFocus?() }
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if isFocused, context.focusHeading.contains(.left) || context.focusHeading.contains(.right) { return false }
        return super.shouldUpdateFocus(in: context)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isFocused else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    @objc private func scrub(_ pan: UIPanGestureRecognizer) {
        guard isFocused else { return }
        switch pan.state {
        case .began:
            onFocus?()
            panStart = position
        case .changed, .ended:
            setPosition(panStart + Double(pan.translation(in: self).x / max(bounds.width, 1)))
        default: break
        }
    }

    @objc private func press(_ tap: UITapGestureRecognizer) {
        guard isFocused, let value = tap.allowedPressTypes.first?.intValue,
              let type = UIPress.PressType(rawValue: value) else { return }
        switch type {
        case .leftArrow: onShuttle?(-1)
        case .rightArrow: onShuttle?(1)
        case .select: onPlay?()
        default: break
        }
    }

    override func accessibilityIncrement() { step(10) }
    override func accessibilityDecrement() { step(-10) }

    private func step(_ seconds: Double) {
        guard duration > 0 else { return }
        setPosition(position + seconds / duration)
    }

    private func setPosition(_ value: Double) {
        position = value.clamped(to: 0...1)
        onSeek?(position)
        setNeedsLayout()
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
