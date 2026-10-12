import SwiftUI

struct ProviderEditorRequest: Identifiable {
    let id = UUID()
    let profile: ProviderProfile?
    let kind: ProviderKind
}

struct ProviderWelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: ProviderEditorRequest?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image("BrandLogo").resizable().scaledToFit().frame(width: 120, height: 120)
                Text("Welcome to Ant Streams").font(.largeTitle.bold())
                Text("Bring your own authorized IPTV provider. No Ant Streams account is needed.").foregroundStyle(.secondary)
                Button("Add Xtream Codes Provider") { editor = ProviderEditorRequest(profile: nil, kind: .xtream) }
                    .buttonStyle(.borderedProminent)
                Button("Add M3U Playlist") { editor = ProviderEditorRequest(profile: nil, kind: .m3u) }
                    .buttonStyle(.bordered)
                if !model.notice.isEmpty {
                    Text(model.notice).font(.callout).foregroundStyle(.secondary)
                    Button("Retry loading saved providers") { Task { await model.restore() } }
                }
                Text("Ant Streams is a player. It does not supply channels, subscriptions or content.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 720, alignment: .leading).padding(32)
        }.background { StreamBackdrop() }
            .sheet(item: $editor) { ProviderEditor(profile: $0.profile, kind: $0.kind) }
    }
}

struct ProviderManagerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ProviderEditorRequest?
    @State private var deleting: ProviderProfile?
    var body: some View {
        NavigationStack {
            List {
                Section("Your providers") {
                    ForEach(model.vault.profiles) { profile in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(profile.provider.name).font(.headline)
                                if profile.id == model.vault.selectedID { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text(profile.provider.kind.title + (profile.provider.usesHTTP ? " · Unencrypted HTTP" : " · HTTPS"))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use provider") {
                                    do { try model.selectProvider(profile.id) } catch { model.notice = error.localizedDescription }
                                }.disabled(profile.id == model.vault.selectedID || model.busy)
                                Button("Edit") { editor = ProviderEditorRequest(profile: profile, kind: profile.provider.kind) }.disabled(model.busy)
                                Button("Delete", role: .destructive) { deleting = profile }.disabled(model.busy)
                            }.buttonStyle(.bordered)
                        }.padding(.vertical, 8)
                    }
                }
                Section("Add provider") {
                    Button("Add Xtream Codes Provider") { editor = ProviderEditorRequest(profile: nil, kind: .xtream) }
                    Button("Add M3U Playlist") { editor = ProviderEditorRequest(profile: nil, kind: .m3u) }
                }.disabled(model.busy)
                Section {
                    Button("Refresh selected provider") { model.refreshProvider() }.disabled(!model.providerReady || model.busy)
                    Text("Credentials and playlist URLs stay in this device's Keychain. They are sent only to your chosen provider and its stream hosts. Profiles do not sync between devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !model.notice.isEmpty { Text(model.notice).font(.callout) }
                }
            }.navigationTitle("Providers")
                .toolbar { Button("Done") { dismiss() }.disabled(model.busy) }
                .sheet(item: $editor) { ProviderEditor(profile: $0.profile, kind: $0.kind) }
                .confirmationDialog("Delete this provider from this device?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Delete provider", role: .destructive) {
                        guard let profile = deleting else { return }
                        do { try model.deleteProvider(profile.id); deleting = nil } catch { model.notice = error.localizedDescription }
                    }
                }
        }
    }
}

struct ProviderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: ProviderProfile?
    @State private var value: Provider
    @State private var error = ""
    @FocusState private var nameFocused: Bool
    init(profile: ProviderProfile?, kind: ProviderKind) {
        self.profile = profile
        _value = State(initialValue: profile?.provider ?? Provider(kind: kind))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(value.kind.title) {
                    TextField("Provider name", text: $value.name).focused($nameFocused)
                    TextField(value.kind == .m3u ? "M3U playlist URL" : "Server URL (http:// or https://)", text: $value.server)
                        .providerTextInput()
                    if value.kind == .xtream {
                        TextField("Username", text: $value.username).providerTextInput()
                        SecureField("Password", text: $value.password).providerTextInput()
                    } else {
                        TextField("XMLTV EPG URL (optional)", text: $value.epgURL).providerTextInput()
                        Text("Supports extended M3U playlists with HTTP/HTTPS stream links and group-title categories. Seasons and episodes require Xtream Codes.").font(.footnote)
                    }
                }
                Section {
                    Label("HTTP is unencrypted. If you use an HTTP provider or stream, others on the network may be able to see your credentials and viewing activity. HTTPS is preferred when your provider supports it.",
                          systemImage: "lock.open").font(.footnote).foregroundStyle(.secondary)
                    Text("Your provider may redirect requests to its media hosts. Ant Streams preserves the scheme and port you enter.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(model.busy ? "Connecting…" : "Connect & save securely") {
                        Task {
                            error = ""
                            do { try await model.saveProvider(value, editing: profile?.id); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(model.busy)
                    if model.busy { ProgressView() }
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(profile == nil ? "Add provider" : "Edit provider")
            .toolbar { Button("Cancel") { dismiss() }.disabled(model.busy) }
            .interactiveDismissDisabled(model.busy)
            .onAppear { nameFocused = true }
        }
    }
}
private extension View {
    @ViewBuilder func providerTextInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
