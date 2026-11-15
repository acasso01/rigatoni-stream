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
        if let asset = Self.fixtureAsset(for: url, loader: fixtureLoader) {
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
        lastError = Self.describe(player.currentItem?.error)
        if !fixtureLoader.note.isEmpty { lastError += " | " + fixtureLoader.note }
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

    /// AVPlayer validates TLS in a media process that does not see the
    /// simulator roots URLSession trusts. Fixture runs fetch localhost HTTPS
    /// with URLSession and answer AVPlayer from that buffer.
    private static func fixtureAsset(for url: URL, loader: FixtureAssetLoader) -> AVURLAsset? {
        guard ProcessInfo.processInfo.environment["ANT_REQUIRE_FIXTURES"] == "1",
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              url.scheme?.lowercased() == "https",
              let rewritten = loader.rewrittenURL(for: url) else { return nil }
        let asset = AVURLAsset(url: rewritten)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return asset
    }

    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown" }
        var text = "\(error.localizedDescription) [\(error.domain) \(error.code)]"
        if let reason = error.localizedFailureReason, !reason.isEmpty, reason != error.localizedDescription { text += " \(reason)" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " underlying \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }
}

/// Serves a localhost fixture URL to AVPlayer using URLSession, which trusts
/// the simulator's installed test CA. Bytes are returned on the resource
/// loader queue and only for the range AVPlayer asked for.
final class FixtureAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ant-streams-fixture-asset")
    private let noteLock = NSLock()
    private var storedNote = ""
    var note: String { noteLock.lock(); defer { noteLock.unlock() }; return storedNote }
    private func setNote(_ text: String) { noteLock.lock(); storedNote = text; noteLock.unlock() }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
    private var sources: [String: URL] = [:]
    private var bodies: [URL: Data] = [:]
    private var pending: [URL: [AVAssetResourceLoadingRequest]] = [:]
    private var inflight: Set<URL> = []

    func rewrittenURL(for url: URL) -> URL? {
        let token = UUID().uuidString
        let name = url.lastPathComponent.isEmpty ? "media" : url.lastPathComponent
        guard let rewritten = URL(string: "antfixture://local/\(token)/\(name)") else { return nil }
        queue.sync { sources[token] = url }
        return rewritten
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let remote = remoteURL(from: loadingRequest.request.url) else {
            setNote("unmapped \(loadingRequest.request.url?.absoluteString ?? "")")
            return false
        }
        if let data = bodies[remote] {
            fulfill(loadingRequest, remote: remote, data: data)
            return true
        }
        pending[remote, default: []].append(loadingRequest)
        guard inflight.insert(remote).inserted else { return true }
        session.dataTask(with: remote) { [weak self] data, response, error in
            self?.queue.async { self?.complete(remote, data: data, response: response, error: error) }
        }.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for url in Array(pending.keys) {
            guard var requests = pending[url] else { continue }
            requests.removeAll { $0 === loadingRequest }
            pending[url] = requests
        }
    }

    private func remoteURL(from requestURL: URL?) -> URL? {
        guard let requestURL else { return nil }
        for piece in requestURL.path.split(separator: "/").map(String.init) {
            if let url = sources[piece] { return url }
        }
        return nil
    }

    private func complete(_ url: URL, data: Data?, response: URLResponse?, error: Error?) {
        inflight.remove(url)
        let waiters = pending.removeValue(forKey: url) ?? []
        if let error {
            setNote("fetch \(error.localizedDescription)")
            waiters.forEach { if !$0.isCancelled { $0.finishLoading(with: error) } }
            return
        }
        guard let data, !data.isEmpty, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = "fetch HTTP \(status) bytes \(data?.count ?? 0)"
            setNote(message)
            let failure = NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
            waiters.forEach { if !$0.isCancelled { $0.finishLoading(with: failure) } }
            return
        }
        bodies[url] = data
        waiters.forEach { if !$0.isCancelled { fulfill($0, remote: url, data: data) } }
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest, remote: URL, data: Data) {
        if request.isCancelled { return }
        let type = Self.contentType(for: remote)
        if let info = request.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            info.contentType = type
            info.contentLength = Int64(data.count)
        }
        var served = 0
        var start = 0
        if let dataRequest = request.dataRequest {
            let start64 = dataRequest.requestedOffset
            if start64 >= 0, start64 < Int64(data.count) {
                start = Int(start64)
                let remaining = data.count - start
                var count = dataRequest.requestedLength
                if count <= 0 || count > remaining { count = remaining }
                if count > 0 {
                    dataRequest.respond(with: data.subdata(in: start..<(start + count)))
                    served = count
                }
            }
        }
        setNote("served \(served) at \(start) of \(data.count) \(type)")
        request.finishLoading()
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "public.m3u-playlist"
        case "ts": return "public.mpeg-2-transport-stream"
        case "mov": return AVFileType.mov.rawValue
        default: return AVFileType.mp4.rawValue
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
