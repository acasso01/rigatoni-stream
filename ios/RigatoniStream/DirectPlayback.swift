import SwiftUI
import AVFoundation
import AVKit

enum PlaybackRouting {
    static func usesApple(extension ext: String, preference: String) -> Bool {
        preference == "apple" || (preference == "auto" && ["m3u8", "mp4", "m4v", "mov"].contains(ext.lowercased()))
    }
    static func usesApple(extension ext: String, preference: String, kind: LibraryKind) -> Bool {
        // Some Xtream HLS endpoints behave differently in AVPlayer and can
        // fail on redirects/auth even when VLC can play the same direct URL.
        // Keep automatic Live TV playback on VLC; users can still force Apple.
        if kind == .live && preference == "auto" { return false }
        return usesApple(extension: ext, preference: preference)
    }
}

@MainActor final class ApplePlayback: ObservableObject {
    let player = AVPlayer()
    @Published var failed = false
    @Published var notice = ""
    private var observation: NSKeyValueObservation?
    private var clock: Any?
    private var failureObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var url: URL?
    private var live = false
    private var retries = 0
    private var stalledSince: Date?
    private var resume = 0.0
    private(set) var seconds = 0.0
    var record: ((Double, Double) -> Void)?
    func open(_ url: URL, live: Bool, start: Double) {
        stop(); self.url = url; self.live = live; resume = start; seconds = start; retries = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        load()
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let current = time.seconds; let duration = self.player.currentItem?.duration.seconds ?? 0
                if current.isFinite { self.seconds = current; if !self.live { self.record?(current, duration) } }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStall() }
        }
    }
    private func load() {
        guard let url else { return }
        failed = false; notice = ""; stalledSince = Date()
        observation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        // AVURLAssetHTTPHeaderFieldsKey is not in the current SDK. The user-agent
        // key is a String so HLS and MP4 requests use the same player agent.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPUserAgentKey": ProviderHTTP.userAgent])
        let item = AVPlayerItem(asset: asset)
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.fail() }
                else if item.status == .readyToPlay {
                    if !self.live, self.resume > 0 {
                        self.player.seek(to: CMTime(seconds: self.resume, preferredTimescale: 600))
                        self.resume = 0
                    }
                    self.player.play()
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }; self.fail()
            }
        }
        player.replaceCurrentItem(with: item); player.play()
    }
    private func fail() {
        guard !failed else { return }
        if live, retries < 2 { retries += 1; load(); return }
        let host = url.map(ProviderHTTP.endpoint) ?? "the provider"
        failed = true; notice = "The Apple player could not play this stream from \(host). Try VLC compatibility playback."
        player.pause()
    }
    private func checkStall() {
        guard !failed else { return }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if stalledSince == nil { stalledSince = Date() }
            if Date().timeIntervalSince(stalledSince ?? Date()) > 25 { fail() }
        } else { stalledSince = nil }
    }
    func stop() {
        player.pause()
        if let clock { player.removeTimeObserver(clock) }; clock = nil
        observation = nil; watchdog?.invalidate(); watchdog = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

struct AppleVideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        #if os(tvOS)
        // Keep tvOS focus in the SwiftUI control overlay so provider fallback
        // is reachable with the Siri Remote. iOS keeps the native controls.
        controller.showsPlaybackControls = false
        #else
        controller.showsPlaybackControls = true
        #endif
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

struct DirectPlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    let provider: Provider
    var channels: [CatalogItem] = []
    var startSeconds: Double = 0
    var progressID: String? = nil
    @AppStorage("ant-playback-engine") private var preference = "auto"
    @StateObject private var apple = ApplePlayback()
    @State private var fallback = false
    @State private var selected: CatalogItem?
    @State private var fallbackSeconds = 0.0
#if os(tvOS)
    @FocusState private var playbackControlFocus: String?
#endif
    private var current: CatalogItem { selected ?? item }
    private var useApple: Bool { !fallback && PlaybackRouting.usesApple(extension: current.fileExtension, preference: preference, kind: current.kind) }
    var body: some View {
        Group {
            if useApple {
                ZStack {
                    Color.black.ignoresSafeArea()
#if os(tvOS)
                    Button { toggleApplePlayback() } label: {
                        AppleVideoSurface(player: apple.player).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    // A real focusable surface gives Up on the Siri Remote a
                    // deterministic path to the VLC action above the video.
                    .focused($playbackControlFocus, equals: "surface")
                    .accessibilityLabel("Video playback")
                    .onMoveCommand { direction in
                        if direction == .up { playbackControlFocus = "vlc" }
                    }
#else
                    AppleVideoSurface(player: apple.player).ignoresSafeArea()
#endif
                    VStack {
                        HStack {
                            Button("Back") { apple.stop(); dismiss() }
                            Text(current.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Button { toggleApplePlayback() } label: {
                                Label("Play/Pause", systemImage: "playpause.fill")
                            }
#if os(tvOS)
                                .focused($playbackControlFocus, equals: "toggle")
#endif
                            if current.kind == .live {
                                Button("Previous") { change(-1) }.disabled(adjacent(-1) == nil)
                                Button("Next") { change(1) }.disabled(adjacent(1) == nil)
                            }
                            Button { switchToVLC() } label: { Label("Use VLC", systemImage: "play.rectangle.on.rectangle") }
#if os(tvOS)
                                .buttonStyle(.borderedProminent)
                                .focused($playbackControlFocus, equals: "vlc")
#endif
                        }
                        .font(.callout).padding().background(.black.opacity(0.78))
#if os(tvOS)
                        .focusSection()
#endif
                        Spacer()
                        if !apple.notice.isEmpty { Text(apple.notice).padding().background(.black.opacity(0.8)) }
                    }.foregroundStyle(.white)
#if os(tvOS)
                    .defaultFocus($playbackControlFocus, "surface")
                    .task {
                        // Wait for the video surface to join the focus tree so
                        // the first Up press has a reliable route to Use VLC.
                        await Task.yield()
                        playbackControlFocus = "surface"
                    }
#endif
                }
#if os(tvOS)
                .onMoveCommand { direction in
                    if direction == .up { playbackControlFocus = "vlc" }
                }
                .onPlayPauseCommand { toggleApplePlayback() }
#endif
                .task(id: current.scopedID) {
                    do {
                        let url = try model.provider(for: current).streamURL(item: current)
                        apple.record = { seconds, duration in model.saveProgress(id: progressID ?? current.id, seconds: seconds, duration: duration) }
                        apple.open(url, live: current.kind == .live, start: selected == nil ? startSeconds : 0)
                        #if os(iOS)
                        MobileRecords.watched(current, episode: progressID != nil, model: model)
                        #else
                        TVLastWatched.record(kind: progressID != nil ? "series" : current.kind == .live ? "live" : "movie", item: current, progressID: progressID, model: model)
                        #endif
                    } catch { apple.notice = "This stream URL could not be opened." }
                }
                .onChange(of: apple.failed) { _, failed in if failed && preference == "auto" { switchToVLC() } }
                .onDisappear { apple.stop() }
            } else {
                #if os(iOS)
                PlayerView(item: current, provider: model.provider(for: current), channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds, progressID: progressID)
                #else
                TVPlayerView(item: current, provider: model.provider(for: current), channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds,
                             lastWatchedKind: progressID == nil ? nil : "series", progressID: progressID)
                #endif
            }
        }
    }
    private func toggleApplePlayback() {
        if apple.player.timeControlStatus == .playing { apple.player.pause() }
        else { apple.player.play() }
    }
    private func switchToVLC() { fallbackSeconds = max(startSeconds, apple.seconds); apple.stop(); fallback = true }
    private func adjacent(_ offset: Int) -> CatalogItem? {
        guard let index = channels.firstIndex(where: { $0.scopedID == current.scopedID }), channels.indices.contains(index + offset) else { return nil }
        return channels[index + offset]
    }
    private func change(_ offset: Int) { if let next = adjacent(offset) { selected = next } }
}
