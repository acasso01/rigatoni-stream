import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
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
                    Button("Add, edit or switch providers") { providers = true }.focused($entryFocused)
                    Button("Refresh provider") { model.refreshProvider() }
                    if model.provider.usesHTTP { Label("This provider uses unencrypted HTTP.", systemImage: "lock.open").font(.system(size: 20)) }
                }
                group("Appearance") {
                    Picker("Theme", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.segmented)
                    Button("Hidden categories / channels") { customization = true }
                }
                group("Playback") {
                    Picker("Player", selection: $engine) {
                        Text("Automatic").tag("auto"); Text("VLC compatibility").tag("vlc"); Text("Apple player").tag("apple")
                    }
                    Picker("Live TV buffer (VLC)", selection: $liveBuffer) {
                        Text("Low delay · 1.5 seconds").tag(1500); Text("Balanced · 3 seconds").tag(3000); Text("More stable · 6 seconds").tag(6000)
                    }
                    Picker("Movie buffer (VLC)", selection: $movieBuffer) {
                        Text("4 seconds").tag(4000); Text("8 seconds").tag(8000); Text("12 seconds").tag(12000)
                    }
                    Text("Automatic uses Apple playback for HLS/MP4 and VLC for other containers or decoding failures. Original quality is preserved.")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                }
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
