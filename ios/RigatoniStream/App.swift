import SwiftUI

@main
struct RigatoniStreamApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    init() {
        AppAppearance.migrateStoredSelection()
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if model.starting { ProgressView("Opening Ant Streams…") }
                else if model.providerReady {
                    MobileRootView().id(model.vault.selectedID)
                } else { ProviderWelcomeView() }
            }
            .environmentObject(model).environmentObject(model.catalog).tint((AppAppearance(rawValue: appearance) ?? .dark).accent)
            .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .environment(\.colorScheme, (AppAppearance(rawValue: appearance) ?? .dark).scheme)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .dark).scheme).task { await model.restore() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var providers = false
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    @AppStorage("ant-playback-engine") private var engine = "auto"
    var body: some View {
        NavigationStack {
            Form {
                Section("Providers") {
                    Text(model.provider.name).font(.headline)
                    Button("Add, edit or switch providers") { providers = true }
                    Button("Refresh provider") { model.refreshProvider() }
                    if model.provider.usesHTTP { Label("This provider uses unencrypted HTTP.", systemImage: "lock.open").font(.footnote) }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) } }
                    NavigationLink("Hidden categories / channels") { LibraryCustomizationView() }
                }
                Section("Playback") {
                    Picker("Player", selection: $engine) {
                        Text("Automatic (Apple + VLC fallback)").tag("auto")
                        Text("VLC compatibility").tag("vlc")
                        Text("Apple player").tag("apple")
                    }
                    Picker("Live TV buffer (VLC)", selection: $liveBuffer) {
                        Text("Low delay · 1.5 seconds").tag(1500); Text("Balanced · 3 seconds").tag(3000); Text("More stable · 6 seconds").tag(6000)
                    }
                    Picker("Movie buffer (VLC)", selection: $movieBuffer) {
                        Text("4 seconds").tag(4000); Text("8 seconds").tag(8000); Text("12 seconds").tag(12000)
                    }
                    Text("Original stream quality. HD/4K depends on the source, codec and device. Apple playback uses its own adaptive buffer.").font(.footnote)
                }
                if !model.notice.isEmpty { Section { Text(model.notice).font(.callout) } }
                Section("About") {
                    Text("Ant Streams · Standalone IPTV player. No channels or subscriptions supplied.")
                    Link("VideoLAN and VLCKit source (LGPL 2.1)", destination: URL(string: "https://code.videolan.org/videolan/VLCKit")!)
                }
            }.navigationTitle("Settings")
                .toolbar { Button("Done") { dismiss() } }
                .sheet(isPresented: $providers) { ProviderManagerView() }
        }
    }
}
