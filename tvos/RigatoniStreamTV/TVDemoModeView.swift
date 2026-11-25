import SwiftUI

/// A self-contained first-run path for App Review and people evaluating the
/// app without IPTV credentials. The only media URL is Blender Foundation's
/// openly licensed Sintel release; the “channel” is the same prerecorded film,
/// called out as a simulation throughout the UI.
struct TVDemoModeView: View {
    var onExit: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var playing: CatalogItem?

    private let movie = CatalogItem(
        id: "demo-sintel",
        name: "Sintel · Licensed Sample Film",
        kind: .movies,
        fileExtension: "mp4",
        poster: nil,
        playbackURL: URL(string: "https://www.peach.themazzone.com/durian/movies/sintel-1280-surround.mp4"),
        categoryID: "demo",
        isDemo: true
    )

    private var demoChannel: CatalogItem {
        CatalogItem(
            id: "demo-channel-sintel",
            name: "Demo Channel · Prerecorded Sample",
            kind: .live,
            fileExtension: "mp4",
            poster: nil,
            playbackURL: movie.playbackURL,
            categoryID: "demo",
            number: "DEMO",
            isDemo: true
        )
    }

    private var visibleItems: [CatalogItem] {
        let all = [movie, demoChannel]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Explore Ant Streams")
                                .font(.largeTitle.bold())
                            Text("Demo mode · No provider account required")
                                .font(.title3)
                                .foregroundStyle(TVTheme.muted)
                            Text("Browse and play licensed sample content. The demo channel is prerecorded footage and does not carry live programming.")
                                .font(.body)
                                .foregroundStyle(TVTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 20)
                        Button("Set Up Provider", action: onExit)
                            .buttonStyle(.card)
                    }

                    TextField("Search demo content", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityLabel("Search demo content")
                        .frame(maxWidth: 760)

                    Text(query.isEmpty ? "Featured Demo Content" : "Search Results")
                        .font(.title2.bold())

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 24)], spacing: 22) {
                        ForEach(visibleItems) { item in
                            Button { playing = item } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    ZStack(alignment: .bottomLeading) {
                                        RoundedRectangle(cornerRadius: 22)
                                            .fill(LinearGradient(
                                                colors: [Color(red: 0.10, green: 0.28, blue: 0.54), Color(red: 0.30, green: 0.18, blue: 0.47)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                            .frame(height: 205)
                                        Image(systemName: item.kind == .live ? "dot.radiowaves.left.and.right" : "film")
                                            .font(.system(size: 58, weight: .light))
                                            .foregroundStyle(.white.opacity(0.82))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        Text(item.kind == .live ? "SIMULATED · PRERECORDED" : "CC BY 3.0 · FULL FILM")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(.black.opacity(0.5), in: Capsule())
                                            .padding(16)
                                    }
                                    Text(item.name)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(item.kind == .live
                                         ? "Sample playback to explore player controls; this is not a live broadcast."
                                         : "Sintel (2010), a complete Blender Foundation open movie. End credits are included.")
                                        .font(.callout)
                                        .foregroundStyle(TVTheme.muted)
                                        .lineLimit(3)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 28))
                            }
                            .buttonStyle(TVCardButtonStyle())
                            .accessibilityHint("Plays a licensed prerecorded sample")
                        }
                    }

                    if visibleItems.isEmpty {
                        Text("No demo content matches that search.")
                            .foregroundStyle(TVTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Film credit and license")
                            .font(.headline)
                        Text("Sintel © Blender Foundation, 2010 · Creative Commons Attribution 3.0. The full film and credit roll are included.")
                            .font(.footnote)
                            .foregroundStyle(TVTheme.muted)
                        Link("View Blender Foundation license details", destination: URL(string: "https://durian.blender.org/about/")!)
                            .font(.footnote)
                    }
                    .padding(.top, 8)

                    Button("Exit Demo") { onExit() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 42)
            }
            .background { StreamBackdrop() }
            .fullScreenCover(item: $playing) { item in
                TVPlayerView(item: item, provider: Provider(), channels: [demoChannel], lastWatchedKind: "demo")
            }
        }
        .environmentObject(model)
    }
}
