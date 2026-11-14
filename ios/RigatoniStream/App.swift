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
                } else if model.needsProviderSetup { ProviderSetupView() }
                else { ProviderWelcomeView() }
            }
            .environmentObject(model).environmentObject(model.catalog).tint((AppAppearance(rawValue: appearance) ?? .dark).accent)
            .foregroundStyle(StreamTheme.text(for: AppAppearance(rawValue: appearance) ?? .dark))
            .environment(\.colorScheme, (AppAppearance(rawValue: appearance) ?? .dark).scheme)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .dark).scheme).task { await model.restore() }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var createAccount = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 100, height: 100).accessibilityHidden(true)
                    Text("Ant Streams").font(.largeTitle.weight(.bold))
                    Text(createAccount ? "Create your account" : "Sign in to sync").font(.title.bold())
                    Text("Optional. Syncs a provider with your Ant Streams account and unlocks the HTTPS gateway.").foregroundStyle(.secondary)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $password) }
                            else { SecureField("Password", text: $password) }
                        }.textContentType(createAccount ? .newPassword : .password)
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }.accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    Button(createAccount ? "Create account" : "Sign in") { Task { await authenticate() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(.white)
                        .disabled(model.busy || email.isEmpty || password.isEmpty)
                    Button(createAccount ? "Already have an account? Sign in" : "Create an account") { createAccount.toggle(); model.notice = "" }
                    Button("Forgot password?") {
                        Task {
                            model.busy = true; defer { model.busy = false }
                            do { try await model.account.recover(email: email); model.notice = "Check your email for the password reset link." }
                            catch { model.notice = error.localizedDescription }
                        }
                    }.disabled(email.isEmpty || model.busy)
                    if model.busy { ProgressView() }
                    if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    Text("Direct providers work without an account. A signed-in provider is also stored in the encrypted account vault. The password you type here is the account password, not the provider password.").font(.footnote).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(28).padding(.top, 35)
            }.background { StreamBackdrop() }
            .navigationTitle("Account")
            .toolbar { Button("Close") { dismiss() } }
        }
    }
    private func authenticate() async {
        model.busy = true; model.notice = ""; defer { model.busy = false }
        do {
            if createAccount {
                guard try await model.account.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) else {
                    password = ""; model.notice = "Check your email to confirm your account, then sign in."; return
                }
            } else { try await model.account.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
            password = ""; model.signedIn = true
            do { try await model.reloadSettings() } catch { model.notice = "Signed in. \(error.localizedDescription)"; model.settingsVisible = true }
            dismiss()
        } catch { model.notice = error.localizedDescription }
    }
}

struct ProviderSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var visiblePassword = false
    @State private var showAccount = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 100, height: 100).accessibilityHidden(true)
                    Text("Ant Streams").font(.largeTitle.weight(.bold))
                    Text("Set up your provider").font(.title.bold())
                    Text("Enter the server URL, username, and password from your IPTV provider. An Ant Streams account is not required.").foregroundStyle(.secondary)
                    TextField("Server URL", text: $model.provider.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $model.provider.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Group {
                            if visiblePassword { TextField("Provider password", text: $model.provider.password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                            else { SecureField("Provider password", text: $model.provider.password) }
                        }
                        Button { visiblePassword.toggle() } label: { Image(systemName: visiblePassword ? "eye.slash" : "eye") }.accessibilityLabel(visiblePassword ? "Hide password" : "Show password")
                    }
                    TextField("Name (optional)", text: $model.providerName)
                    Button("Start watching") { Task { await model.saveSettings() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(.white)
                        .disabled(model.busy || model.provider.server.isEmpty || model.provider.username.isEmpty || model.provider.password.isEmpty)
                    Button("Sign in to sync") { showAccount = true }
                    if model.busy { ProgressView() }
                    if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    Text("The provider login is saved in this device's Keychain only. Direct providers play immediately. The HTTPS gateway is optional, lives in Settings, and needs an Ant Streams sign-in.").font(.footnote).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(28).padding(.top, 35)
            }.background { StreamBackdrop() }
            .sheet(isPresented: $showAccount) { LoginView() }
        }
    }
}

private struct AddLocalProviderSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var visiblePassword = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    if visiblePassword { TextField("Provider password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { SecureField("Provider password", text: $password) }
                    Button { visiblePassword.toggle() } label: { Image(systemName: visiblePassword ? "eye.slash" : "eye") }.accessibilityLabel("Show or hide provider password")
                }
                TextField("Name (optional)", text: $name)
            }
            .navigationTitle("Add provider")
            .toolbar {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        let saved = await model.addLocalProvider(name: name, provider: Provider(server: server, username: username, password: password), gateway: "")
                        if saved { password = ""; dismiss() }
                    }
                }.disabled(model.busy || server.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var providers = false
    @State private var deleting = false
    @State private var visiblePassword = false
    @State private var addingProvider = false
    @State private var showAccount = false
    @State private var pendingRemoval: String?
    @AppStorage("rigatoni-appearance") private var appearance = AppAppearance.dark.rawValue
    @AppStorage("ant-library-mode") private var libraryModeRaw = LibraryMode.separate.rawValue
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
                Section("Live TV Guide") { EPGRefreshControl() }
                Section("Theme") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Text("Dark, iOS Light, or Xfinity — the X1-style navy look. Saved on this device only.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Library") {
                    StreamOptionPicker(options: LibraryMode.allCases.map { ($0, $0.title) }, selection: Binding(
                        get: { LibraryMode(rawValue: libraryModeRaw) ?? .separate },
                        set: { model.setLibraryMode($0) }
                    ))
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                    Text(model.libraryMode.blurb).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    ForEach(AppAppearance.allCases) { theme in
                        Button { appearance = theme.rawValue } label: {
                            HStack {
                                Text(theme.title)
                                Spacer()
                                if appearance == theme.rawValue {
                                    Image(systemName: "checkmark").foregroundStyle(StreamTheme.accent)
                                }
                            }
                        }.foregroundStyle(StreamTheme.text)
                    }
                    LibraryFilterToggles()
                    NavigationLink("Categories, order and names") { LibraryCustomizationView() }
                }
                Section("Provider") {
                    Text(model.provider.requiresGateway
                         ? (model.signedIn ? "Playback route: HTTPS gateway" : "Playback route: HTTPS gateway — sign in required. Direct providers still play.")
                         : "Playback route: direct provider")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Server URL", text: $model.provider.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $model.provider.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        if visiblePassword { TextField("Provider password", text: $model.provider.password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        else { SecureField("Provider password", text: $model.provider.password) }
                        Button { visiblePassword.toggle() } label: { Image(systemName: visiblePassword ? "eye.slash" : "eye") }.accessibilityLabel("Show or hide provider password")
                    }
                    TextField("Name (optional)", text: $model.providerName)
                    TextField("HTTPS gateway URL (optional)", text: $model.gateway).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(model.signedIn
                         ? "Configured HTTP providers and HTTPS providers play directly. Other HTTP providers use your saved HTTPS gateway."
                         : "Direct providers play without an account. The HTTPS gateway needs an Ant Streams sign-in and does not block a direct provider.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save provider & gateway") { Task { await model.saveSettings() } }.disabled(model.busy)
                    Button("Reload saved settings") { Task {
                        model.busy = true; defer { model.busy = false }
                        do { try await model.reloadSettings() } catch { model.notice = error.localizedDescription }
                    } }.disabled(model.busy)
                    if !model.signedIn {
                        Button("Add another provider") { addingProvider = true }
                            .disabled(model.busy || model.localProviders.count >= LocalProviderVault.limit)
                        ForEach(model.localProviders) { item in
                            VStack(alignment: .leading) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.displayName)
                                        Text(item.hostLabel).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.id == model.activeLocalID { Text("In use").font(.footnote).foregroundStyle(.secondary) }
                                    else { Button("Use") { model.useLocalProvider(item.id) }.disabled(model.busy) }
                                }
                                Button("Remove \(item.displayName)", role: .destructive) { pendingRemoval = item.id }
                                    .disabled(model.busy)
                            }
                        }
                    }
                }
                if model.signedIn && !model.localProviders.isEmpty {
                    Section("On this device") {
                        Text("These providers stay on this device and are used after you sign out.").font(.footnote).foregroundStyle(.secondary)
                        ForEach(model.localProviders) { item in
                            VStack(alignment: .leading) {
                                Text(item.displayName)
                                Text(item.hostLabel).font(.footnote).foregroundStyle(.secondary)
                                Button("Remove \(item.displayName)", role: .destructive) { pendingRemoval = item.id }.disabled(model.busy)
                            }
                        }
                    }
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
                if !model.notice.isEmpty { Section { Text(model.notice).font(.callout).foregroundStyle(.secondary) } }
                Section(model.signedIn ? "Account" : "Sign in to sync") {
                    if model.signedIn {
                        if let email = model.account.session?.user.email { Text("Signed in as \(email)") }
                        Text("Provider settings sync to your Ant Streams account. The HTTPS gateway uses this sign-in.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }.disabled(model.busy)
                    } else {
                        Text("Optional. Sign in to copy this provider to your Ant Streams account and to use the HTTPS gateway.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in to sync") { showAccount = true }.disabled(model.busy)
                    }
                    Button(model.signedIn ? "Delete saved provider & gateway" : "Remove this provider", role: .destructive) { deleting = true }.disabled(model.busy)
                }
                Section("About") {
                    Text("Ant Streams · Standalone IPTV player. No channels or subscriptions supplied.")
                    Link("VideoLAN and VLCKit source (LGPL 2.1)", destination: URL(string: "https://code.videolan.org/videolan/VLCKit")!)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() }.disabled(model.busy) }
            .sheet(isPresented: $providers) { ProviderManagerView() }
            .sheet(isPresented: $showAccount) { LoginView() }
            .sheet(isPresented: $addingProvider) { AddLocalProviderSheet() }
            .confirmationDialog(model.signedIn ? "Delete your saved provider and gateway from your account?" : "Remove this provider from this device?", isPresented: $deleting, titleVisibility: .visible) {
                Button(model.signedIn ? "Delete settings" : "Remove provider", role: .destructive) { Task { await model.deleteSettings() } }
            }
            .confirmationDialog("Remove this provider from this device?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) {
                    if let id = pendingRemoval { Task { await model.removeLocalProvider(id) } }
                    pendingRemoval = nil
                }
            }
        }
    }
}
