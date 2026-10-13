import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @AppStorage("ant-library-mode") private var libraryModeRaw = LibraryMode.separate.rawValue
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    @AppStorage("ant-playback-engine") private var engine = "auto"
    @State private var providers = false
    @State private var customization = false
    @FocusState private var entryFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Settings").font(.system(size: 36, weight: .bold))
                group("Providers") {
                    Text(model.provider.name).font(.headline)
                    Button("Add, edit or switch providers") { providers = true }.focused($entryFocused).buttonStyle(TVCompactButtonStyle())
                    Button("Refresh provider") { model.refreshProvider() }.buttonStyle(TVCompactButtonStyle())
                    if model.provider.usesHTTP { Label("This provider uses unencrypted HTTP.", systemImage: "lock.open").font(.system(size: 20)) }
                }
                group("Library") {
                    StreamOptionPicker(options: LibraryMode.allCases.map { ($0, $0.title) }, selection: Binding(
                        get: { LibraryMode(rawValue: libraryModeRaw) ?? .separate },
                        set: { model.setLibraryMode($0) }
                    ))
                    Text(model.libraryMode.blurb).font(.system(size: 20)).foregroundStyle(.secondary)
                }
                group("Appearance") {
                    StreamOptionPicker(options: AppAppearance.allCases.map { ($0.rawValue, $0.title) }, selection: $appearance)
                    Button("Hidden categories / channels") { customization = true }.buttonStyle(TVCompactButtonStyle())
                }
                group("Playback") {
                    Text("Player").font(.system(size: 22, weight: .semibold))
                    StreamOptionPicker(options: [("auto", "Automatic"), ("vlc", "VLC compatibility"), ("apple", "Apple player")], selection: $engine)
                    Text("Live TV buffer (VLC)").font(.system(size: 22, weight: .semibold))
                    StreamOptionPicker(options: [(1500, "Low delay · 1.5 seconds"), (3000, "Balanced · 3 seconds"), (6000, "More stable · 6 seconds")], selection: $liveBuffer)
                    Text("Movie buffer (VLC)").font(.system(size: 22, weight: .semibold))
                    StreamOptionPicker(options: [(4000, "4 seconds"), (8000, "8 seconds"), (12000, "12 seconds")], selection: $movieBuffer)
                    Text("Automatic uses Apple playback for HLS/MP4 and VLC for other containers or decoding failures. Original quality is preserved.")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                }
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                if !model.notice.isEmpty { Text(model.notice).font(.system(size: 22)) }
                Text("Ant Streams · Bring your own authorized provider. No channels or subscriptions supplied.")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
            }.frame(maxWidth: 1100, alignment: .leading).padding(48)
        }.background { StreamBackdrop() }
            .onAppear { entryFocused = true }
            .sheet(isPresented: $providers) { ProviderManagerView() }
            .fullScreenCover(isPresented: $customization) { NavigationStack { LibraryCustomizationView() }.onExitCommand { customization = false } }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title).font(.system(size: 28, weight: .bold))
            content()
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 18)).focusSection()
    }
}
