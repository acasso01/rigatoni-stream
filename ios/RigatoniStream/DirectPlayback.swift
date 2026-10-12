import SwiftUI
import AVKit

enum PlaybackRouting {
    static func usesApple(extension ext: String, preference: String) -> Bool {
        preference == "apple" || (preference == "auto" && ["m3u8", "mp4", "m4v", "mov"].contains(ext.lowercased()))
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
        let item = AVPlayerItem(url: url)
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
        failed = true; notice = "The Apple player could not play this stream. Try VLC compatibility playback."
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
        controller.player = player; controller.showsPlaybackControls = true
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
    private var current: CatalogItem { selected ?? item }
    private var useApple: Bool { !fallback && PlaybackRouting.usesApple(extension: current.fileExtension, preference: preference) }
    var body: some View {
        Group {
            if useApple {
                ZStack {
                    Color.black.ignoresSafeArea()
                    AppleVideoSurface(player: apple.player).ignoresSafeArea()
                    VStack {
                        HStack {
                            Button("Back") { apple.stop(); dismiss() }
                            Text(current.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if current.kind == .live {
                                Button("Previous") { change(-1) }.disabled(adjacent(-1) == nil)
                                Button("Next") { change(1) }.disabled(adjacent(1) == nil)
                            }
                            Button("Use VLC") { switchToVLC() }
                        }.font(.callout).padding().background(.black.opacity(0.6))
                        Spacer()
                        if !apple.notice.isEmpty { Text(apple.notice).padding().background(.black.opacity(0.8)) }
                    }.foregroundStyle(.white)
                }
                .task(id: current.id) {
                    do {
                        let url = try provider.streamURL(item: current)
                        apple.record = { seconds, duration in model.saveProgress(id: progressID ?? current.id, seconds: seconds, duration: duration) }
                        apple.open(url, live: current.kind == .live, start: selected == nil ? startSeconds : 0)
                        #if os(iOS)
                        MobileRecords.watched(current, episode: progressID != nil, model: model)
                        #else
                        TVLastWatched.record(kind: progressID != nil ? "series" : current.kind == .live ? "live" : "movie", item: current, model: model)
                        #endif
                    } catch { apple.notice = "This stream URL could not be opened." }
                }
                .onChange(of: apple.failed) { _, failed in if failed && preference == "auto" { switchToVLC() } }
                .onDisappear { apple.stop() }
            } else {
                #if os(iOS)
                PlayerView(item: current, provider: provider, channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds, progressID: progressID)
                #else
                TVPlayerView(item: current, provider: provider, channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds,
                             lastWatchedKind: progressID == nil ? nil : "series", progressID: progressID)
                #endif
            }
        }
    }
    private func switchToVLC() { fallbackSeconds = max(startSeconds, apple.seconds); apple.stop(); fallback = true }
    private func adjacent(_ offset: Int) -> CatalogItem? {
        guard let index = channels.firstIndex(where: { $0.id == current.id }), channels.indices.contains(index + offset) else { return nil }
        return channels[index + offset]
    }
    private func change(_ offset: Int) { if let next = adjacent(offset) { selected = next } }
}
