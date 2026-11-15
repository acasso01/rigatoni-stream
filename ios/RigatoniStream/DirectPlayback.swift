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
    private(set) var lastError = ""
    var record: ((Double, Double) -> Void)?
    private let fixtureLoader = FixtureAssetLoader()
    private let fixtureQueue = DispatchQueue(label: "ant-streams-fixture-asset")
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
        let item: AVPlayerItem
        if let asset = Self.fixtureAsset(for: url, loader: fixtureLoader, queue: fixtureQueue) {
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
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
        failed = true
        lastError = player.currentItem?.error?.localizedDescription ?? ""
        notice = "The Apple player could not play this stream. Try VLC compatibility playback."
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

    /// AVPlayer does not use the simulator roots that URLSession trusts.
    /// The local fixture is loaded through URLSession only when CI or a
    /// local fixture run sets ANT_REQUIRE_FIXTURES.
    private static func fixtureAsset(for url: URL, loader: FixtureAssetLoader, queue: DispatchQueue) -> AVURLAsset? {
        guard ProcessInfo.processInfo.environment["ANT_REQUIRE_FIXTURES"] == "1",
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" else { return nil }
        parts.scheme = "fixture-" + scheme
        guard let rewritten = parts.url else { return nil }
        let asset = AVURLAsset(url: rewritten)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        return asset
    }
}

/// Serves a localhost fixture URL to AVPlayer using URLSession, which trusts
/// the simulator's installed test CA.
final class FixtureAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let original = loadingRequest.request.url,
              var parts = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, scheme.hasPrefix("fixture-") else { return false }
        parts.scheme = String(scheme.dropFirst("fixture-".count))
        guard let url = parts.url else { return false }
        var request = URLRequest(url: url)
        if let data = loadingRequest.dataRequest, data.requestedOffset > 0 || !data.requestsAllDataToEndOfResource {
            let end = data.requestsAllDataToEndOfResource ? "" : String(data.requestedOffset + Int64(data.requestedLength) - 1)
            request.setValue("bytes=\(data.requestedOffset)-\(end)", forHTTPHeaderField: "Range")
        }
        session.dataTask(with: request) { data, response, error in
            if let error { loadingRequest.finishLoading(with: error); return }
            guard let data, let http = response as? HTTPURLResponse else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse)); return
            }
            if let info = loadingRequest.contentInformationRequest {
                info.isByteRangeAccessSupported = true
                info.contentType = Self.uti(for: url)
                if let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last, let length = Int64(total) {
                    info.contentLength = length
                } else if http.expectedContentLength > 0 {
                    info.contentLength = http.expectedContentLength
                } else {
                    info.contentLength = Int64(data.count)
                }
            }
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        }.resume()
        return true
    }

    private static func uti(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "public.m3u-playlist"
        case "ts": return "public.mpeg-2-transport-stream"
        default: return "public.mpeg-4"
        }
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
                .task(id: current.scopedID) {
                    do {
                        let url = try model.provider(for: current).streamURL(item: current)
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
                PlayerView(item: current, provider: model.provider(for: current), channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds, progressID: progressID)
                #else
                TVPlayerView(item: current, provider: model.provider(for: current), channels: channels, startSeconds: fallback ? fallbackSeconds : startSeconds,
                             lastWatchedKind: progressID == nil ? nil : "series", progressID: progressID)
                #endif
            }
        }
    }
    private func switchToVLC() { fallbackSeconds = max(startSeconds, apple.seconds); apple.stop(); fallback = true }
    private func adjacent(_ offset: Int) -> CatalogItem? {
        guard let index = channels.firstIndex(where: { $0.scopedID == current.scopedID }), channels.indices.contains(index + offset) else { return nil }
        return channels[index + offset]
    }
    private func change(_ offset: Int) { if let next = adjacent(offset) { selected = next } }
}
