import SwiftUI
import AVFoundation
import MobileVLCKit

@MainActor
final class NativePlayer: ObservableObject {
    let engine = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show"])!
    @Published var state = "Connecting…"
    @Published var playing = false
    @Published var seekable = false
    @Published var position: Double = 0
    @Published var elapsed = "0:00"
    @Published var resolution = ""
    private var timer: Timer?
    private var openedAt = Date()
    private var url: URL?
    private var cache = 1500
    private var dragging = false
    func attach(_ view: UIView, url: URL, cache: Int) {
        engine.drawable = view
        self.url = url; self.cache = cache
        start()
    }
    func start() {
        guard let url else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let media = VLCMedia(url: url)!
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
        let seconds = max(0, Int(engine.time.intValue) / 1000)
        elapsed = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let size = engine.videoSize
        resolution = size.width > 0 ? "\(Int(size.width))×\(Int(size.height)) · Original quality" : ""
        switch engine.state {
        case .playing: state = "Playing"
        case .paused: state = "Paused"
        case .buffering: state = "Buffering…"
        case .error: state = "The stream could not play. Try another title or check the provider connection."
        case .ended: state = "Playback ended"
        default: state = Date().timeIntervalSince(openedAt) > 30 ? "Still waiting for video. Retry or try another title." : "Connecting…"
        }
    }
    func toggle() { if engine.isPlaying { engine.pause() } else { engine.play() } }
    func seekEditing(_ value: Bool) {
        dragging = value
        if !value && engine.isSeekable { engine.position = Float(position) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        engine.stop(); engine.media = nil; engine.drawable = nil; url = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, self)) }
}

struct PlayerSurface: UIViewRepresentable {
    let player: NativePlayer
    let url: URL
    let cache: Int
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black
        player.attach(view, url: url, cache: cache)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {}
}

struct PlayerView: View {
    let item: CatalogItem
    let provider: Provider
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = NativePlayer()
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { player.stop(); dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                Text(item.name).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.padding()
            if let url = item.playbackURL ?? (provider.usesHTTP ? nil : try? provider.streamURL(item: item)) {
                PlayerSurface(player: player, url: url, cache: item.kind == .live ? liveBuffer : movieBuffer)
            } else { Text("Invalid provider settings.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(spacing: 14) {
                HStack {
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2) }.accessibilityLabel(player.playing ? "Pause" : "Play")
                    Text(player.elapsed).monospacedDigit()
                    Spacer()
                    Button("Retry") { player.start() }
                }
                if item.kind == .movies && player.seekable {
                    Slider(value: $player.position, in: 0...1, onEditingChanged: player.seekEditing).accessibilityLabel("Movie position")
                }
                Text(player.state).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if !player.resolution.isEmpty { Text(player.resolution).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding()
        }.background(.black).onDisappear { player.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active && player.playing { player.engine.pause() } }
    }
}
