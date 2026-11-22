import SwiftUI

// Optional account sign-in. Direct providers do not need this. Credentials
// saved without an account stay in the device Keychain, never in preferences,
// logs, or disk caches. A signed-in provider still uses the encrypted vault.
struct TVLoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var createAccount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image("BrandLogo").resizable().scaledToFit().frame(width: 160, height: 160).accessibilityHidden(true)
                Text("Ant Streams")
                    .font(.largeTitle.weight(.bold))
                Text(createAccount ? "Create your account" : "Sign in to sync")
                    .font(.title.bold())
                Text("Optional. Syncs provider settings with your Ant Streams account. Provider playback always connects directly to your provider.")
                    .foregroundStyle(TVTheme.muted)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                HStack {
                    Group {
                        if showPassword { TextField("Password", text: $password) }
                        else { SecureField("Password", text: $password) }
                    }
                    .textContentType(createAccount ? .newPassword : .password)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }

                Button(createAccount ? "Create account" : "Sign in") {
                    Task { await authenticate() }
                }
                .buttonStyle(.card)
                .tint(.white)
                .disabled(model.busy || email.isEmpty || password.isEmpty)

                Button(createAccount ? "Already have an account? Sign in" : "Create an account") {
                    createAccount.toggle(); model.notice = ""
                }
                Button("Forgot password?") {
                    Task {
                        model.busy = true; defer { model.busy = false }
                        do {
                            try await model.account.recover(email: email)
                            model.notice = "Check your email for the password reset link."
                        } catch { model.notice = error.localizedDescription }
                    }
                }
                .disabled(email.isEmpty || model.busy)

                if model.busy { ProgressView() }
                if !model.notice.isEmpty {
                    Text(model.notice).font(.callout).foregroundStyle(TVTheme.muted)
                }
                Text("Direct providers work without an account. This password is for the Ant Streams account, not the IPTV provider.")
                    .font(.footnote)
                    .foregroundStyle(TVTheme.muted)
            }
            .frame(maxWidth: 720)
            .padding(60)
        }
        .background { StreamBackdrop() }
    }

    private func authenticate() async {
        model.busy = true; model.notice = ""; defer { model.busy = false }
        do {
            if createAccount {
                guard try await model.account.signUp(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) else {
                    password = ""
                    model.notice = "Check your email to confirm your account, then sign in."
                    return
                }
            } else {
                try await model.account.signIn(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            }
            password = ""; model.signedIn = true
            do { try await model.reloadSettings(preferAccount: true) }
            catch { model.notice = "Signed in. \(error.localizedDescription)" }
        } catch { model.notice = error.localizedDescription }
    }
}

// First launch, when no provider is saved and nobody is signed in.
// Focus lands on Server URL, matching Settings.
struct TVProviderSetupView: View {
    private enum SetupField: Hashable { case server, username, password, reveal, name, start, sync }

    @EnvironmentObject private var model: AppModel
    @Namespace private var setupFocus
    @FocusState private var focusedField: SetupField?
    // Use the same tvOS keyboard path as Username during first-run setup.
    // The eye control can mask the password after entry.
    @State private var visiblePassword = true
    @State private var showAccount = false
    // Keep credentials local while the setup form is being edited. Writing the
    // first non-empty password character to AppModel makes providerReady true,
    // which would otherwise replace this screen and dismiss the tvOS keyboard.
    @State private var draftServer = ""
    @State private var draftUsername = ""
    @State private var draftPassword = ""
    @State private var draftName = ""

    var body: some View {
        Group {
            if showAccount {
                VStack(alignment: .leading, spacing: 24) {
                    TVLoginView()
                    Button("Back to provider setup") { showAccount = false }
                        .buttonStyle(.card)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Image("BrandLogo").resizable().scaledToFit().frame(width: 140, height: 140).accessibilityHidden(true)
                        Text("Set up your provider")
                            .font(.largeTitle.bold())
                        Text("Enter your IPTV provider. No Ant Streams account is required.")
                            .foregroundStyle(TVTheme.muted)
                        TextField("Server URL", text: $draftServer)
                            .focused($focusedField, equals: .server)
                            .prefersDefaultFocus(in: setupFocus)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .username }
                        TextField("Username", text: $draftUsername)
                            .focused($focusedField, equals: .username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                        HStack {
                            if visiblePassword {
                                TextField("Provider password", text: $draftPassword)
                                    .focused($focusedField, equals: .password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .start }
                            } else {
                                SecureField("Provider password", text: $draftPassword)
                                    .focused($focusedField, equals: .password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .start }
                            }
                            Button {
                                visiblePassword.toggle()
                                focusedField = .password
                            } label: {
                                Image(systemName: visiblePassword ? "eye.slash" : "eye")
                            }
                            .focused($focusedField, equals: .reveal)
                            .accessibilityLabel("Show or hide provider password")
                        }
                        TextField("Name (optional)", text: $draftName)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .start }
                        Button("Start watching") {
                            model.provider = Provider(
                                server: draftServer,
                                username: draftUsername,
                                password: draftPassword,
                                name: draftName
                            )
                            model.providerName = draftName
                            Task { await model.saveSettings() }
                        }
                            .focused($focusedField, equals: .start)
                            .buttonStyle(.card)
                            .tint(.white)
                            .disabled(model.busy || draftServer.isEmpty || draftUsername.isEmpty || draftPassword.isEmpty)
                        Button("Sign in to sync") { showAccount = true }
                            .focused($focusedField, equals: .sync)
                            .buttonStyle(.card)
                        if model.busy { ProgressView() }
                        if !model.notice.isEmpty {
                            Text(model.notice).font(.callout).foregroundStyle(TVTheme.muted)
                        }
                        Text("The provider login is saved in this device's Keychain only. Playback connects directly to the provider server. No Ant Streams account or gateway is required.")
                            .font(.footnote)
                            .foregroundStyle(TVTheme.muted)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(60)
                }
                .focusScope(setupFocus)
                .defaultFocus($focusedField, .server)
            }
        }
        .background { StreamBackdrop() }
        .onAppear {
            draftServer = model.provider.server
            draftUsername = model.provider.username
            draftPassword = model.provider.password
            draftName = model.providerName
            focusedField = .server
        }
        .onChange(of: showAccount) { _, showing in
            if !showing { focusedField = .server }
        }
    }

}

// Settings tab. Provider fields are saved on this device unless an account
// session is active, in which case Save still writes the encrypted vault.
// Right from the nav rail lands on Server URL.
struct TVSettingsView: View {
    private enum ProviderField: Hashable { case username, password, reveal, name, gateway, save, reload }

    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @AppStorage("ant-library-mode") private var libraryModeRaw = LibraryMode.separate.rawValue
    @State private var deleting = false
    @State private var visiblePassword = false
    @State private var pendingRemoval: String?
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    @AppStorage("ant-playback-engine") private var engine = "auto"
    @State private var providers = false
    @State private var customization = false
    @FocusState private var providerField: ProviderField?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .padding(.top, 40)

                    if let email = model.account.session?.user.email {
                        Text("Signed in as \(email)")
                            .foregroundStyle(TVTheme.muted)
                    }

                    settingsGroup(title: "Live TV Guide") { EPGRefreshControl() }
                    settingsGroup(title: "Personalize") {
                        LibraryFilterToggles()
                        NavigationLink("Categories, order and names") { LibraryCustomizationView() }
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                    }
                    settingsGroup(title: "Provider") {
                        Text("Playback route: direct to your provider")
                            .font(.footnote).foregroundStyle(TVTheme.muted)
                        TVEntryControl(section: .settings) {
                            TextField("Server URL", text: $model.provider.server)
                                .tvContentEntry()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.next)
                                .onSubmit { providerField = .username }
                        }
                        TextField("Username", text: $model.provider.username)
                            .focused($providerField, equals: .username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { providerField = .password }
                        HStack {
                            if visiblePassword {
                                TextField("Provider password", text: $model.provider.password)
                                    .focused($providerField, equals: .password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .onSubmit { providerField = .name }
                            } else {
                                SecureField("Provider password", text: $model.provider.password)
                                    .focused($providerField, equals: .password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .onSubmit { providerField = .name }
                            }
                            Button {
                                visiblePassword.toggle()
                                providerField = .password
                            } label: {
                                Image(systemName: visiblePassword ? "eye.slash" : "eye")
                            }
                            .focused($providerField, equals: .reveal)
                            .accessibilityLabel("Show or hide provider password")
                        }
                        TextField("Name (optional)", text: $model.providerName)
                            .focused($providerField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { providerField = .gateway }
                        TextField("Legacy HTTPS gateway URL (optional; not used for playback)", text: $model.gateway)
                            .focused($providerField, equals: .gateway)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.next)
                            .onSubmit { providerField = .save }
                        Text("Provider requests and playback connect directly to the server above. A gateway or Ant Streams account is not required.")
                            .font(.footnote).foregroundStyle(TVTheme.muted)
                        HStack(spacing: 16) {
                            Button("Save provider settings") { Task { await model.saveSettings() } }
                                .focused($providerField, equals: .save)
                                .buttonStyle(.card).tint(.white)
                                .disabled(model.busy || model.provider.server.isEmpty || model.provider.username.isEmpty || model.provider.password.isEmpty)
                            Button("Reload saved settings") {
                                Task {
                                    model.busy = true; defer { model.busy = false }
                                    do { try await model.reloadSettings() }
                                    catch { model.notice = error.localizedDescription }
                                }
                            }
                            .focused($providerField, equals: .reload)
                            .buttonStyle(.card).disabled(model.busy)
                        }
                        Button("Add, edit or switch providers") { providers = true }.buttonStyle(TVCompactButtonStyle())
                        Button("Refresh provider") { model.refreshProvider() }.buttonStyle(TVCompactButtonStyle())
                        if model.provider.usesHTTP { Label("This provider uses unencrypted HTTP.", systemImage: "lock.open").font(.system(size: 20)) }
                        if !model.signedIn && model.localProviders.count < LocalProviderVault.limit {
                            NavigationLink("Add another provider") { TVAddProviderView() }
                                .buttonStyle(.card)
                        }
                        if !model.signedIn {
                            ForEach(model.localProviders) { item in
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading) {
                                        Text(item.displayName)
                                        Text(item.hostLabel).font(.footnote).foregroundStyle(TVTheme.muted)
                                    }
                                    Spacer()
                                    if item.id == model.activeLocalID {
                                        Text("In use").foregroundStyle(TVTheme.muted)
                                    } else {
                                        Button("Use") { model.useLocalProvider(item.id) }
                                            .buttonStyle(.card).disabled(model.busy)
                                    }
                                    Button("Remove") { pendingRemoval = item.id }
                                        .buttonStyle(.card).disabled(model.busy)
                                        .accessibilityLabel("Remove \(item.displayName)")
                                }
                            }
                        }
                    }
                    settingsGroup(title: "Library") {
                        StreamOptionPicker(options: LibraryMode.allCases.map { ($0, $0.title) }, selection: Binding(
                            get: { LibraryMode(rawValue: libraryModeRaw) ?? .separate },
                            set: { model.setLibraryMode($0) }
                        ))
                        Text(model.libraryMode.blurb).font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                    if model.signedIn && !model.localProviders.isEmpty {
                        settingsGroup(title: "On this device") {
                            Text("These providers stay on this device and are used after you sign out.")
                                .font(.footnote).foregroundStyle(TVTheme.muted)
                            ForEach(model.localProviders) { item in
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading) {
                                        Text(item.displayName)
                                        Text(item.hostLabel).font(.footnote).foregroundStyle(TVTheme.muted)
                                    }
                                    Spacer()
                                    Button("Remove") { pendingRemoval = item.id }
                                        .buttonStyle(.card).disabled(model.busy)
                                        .accessibilityLabel("Remove \(item.displayName)")
                                }
                            }
                        }
                    }

                    settingsGroup(title: "Player") {
                        StreamOptionPicker(options: [("auto", "Automatic"), ("vlc", "VLC compatibility"), ("apple", "Apple player")], selection: $engine)
                        Text("Automatic uses Apple playback for HLS/MP4 and VLC for other containers or decoding failures. Original quality is preserved.")
                            .font(.system(size: 20)).foregroundStyle(.secondary)
                    }

                    settingsGroup(title: "Playback buffer") {
                        Picker("Live TV", selection: $liveBuffer) {
                            Text("Low delay · 1.5 seconds").tag(1500)
                            Text("Balanced · 3 seconds").tag(3000)
                            Text("More stable · 6 seconds").tag(6000)
                        }
                        Picker("Movies", selection: $movieBuffer) {
                            Text("4 seconds").tag(4000)
                            Text("8 seconds").tag(8000)
                            Text("12 seconds").tag(12000)
                        }
                        Text("These buffers add delay. Streams keep their original resolution; HD and 4K depend on the source, device and connection.")
                            .font(.footnote).foregroundStyle(TVTheme.muted)
                    }

                    if !model.notice.isEmpty {
                        Text(model.notice).foregroundStyle(TVTheme.muted)
                    }

                    settingsGroup(title: model.signedIn ? "Account" : "Sign in to sync") {
                        if model.signedIn {
                            Text("Your Ant Streams account syncs provider settings. Playback still connects directly to your provider.")
                                .font(.footnote).foregroundStyle(TVTheme.muted)
                        } else {
                            Text("Optional. Sign in to sync provider settings across your Ant Streams account. This does not change the direct playback route.")
                                .font(.footnote).foregroundStyle(TVTheme.muted)
                            NavigationLink("Sign in to sync") { TVLoginView() }
                                .buttonStyle(.card)
                        }
                        HStack(spacing: 16) {
                            Button(model.signedIn ? "Delete saved provider & gateway" : "Remove this provider") { deleting = true }
                                .buttonStyle(.card).disabled(model.busy)
                            if model.signedIn {
                                Button("Sign out") { Task { await model.signOut() } }
                                    .buttonStyle(.card).disabled(model.busy)
                            }
                        }
                    }

                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("Ant Streams 0.2 for tvOS · Native playback by VLCKit / VideoLAN (LGPL 2.1).")
                        .font(.footnote).foregroundStyle(TVTheme.muted)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
            .tvAdoptContentFocusScope()
            .focusSection()
            .background { StreamBackdrop() }
            .confirmationDialog(
                model.signedIn ? "Delete your saved provider and gateway from your account?" : "Remove this provider from this device?",
                isPresented: $deleting, titleVisibility: .visible
            ) {
                Button(model.signedIn ? "Delete settings" : "Remove provider", role: .destructive) { Task { await model.deleteSettings() } }
            }
            .confirmationDialog(
                "Remove this provider from this device?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove provider", role: .destructive) {
                    if let id = pendingRemoval { Task { await model.removeLocalProvider(id) } }
                    pendingRemoval = nil
                }
            }
            .sheet(isPresented: $providers) { ProviderManagerView() }
        }
    }

}

private struct TVAddProviderView: View {
    private enum AddField: Hashable { case server, username, password, reveal, name, save }
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Namespace private var addFocus
    @FocusState private var focusedField: AddField?
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var visiblePassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add provider").font(.largeTitle.bold()).padding(.top, 40)
                TextField("Server URL", text: $server)
                    .focused($focusedField, equals: .server)
                    .prefersDefaultFocus(in: addFocus)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                TextField("Username", text: $username)
                    .focused($focusedField, equals: .username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                HStack {
                    if visiblePassword {
                        TextField("Provider password", text: $password)
                            .focused($focusedField, equals: .password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .name }
                    } else {
                        SecureField("Provider password", text: $password)
                            .focused($focusedField, equals: .password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .name }
                    }
                    Button {
                        visiblePassword.toggle()
                        focusedField = .password
                    } label: {
                        Image(systemName: visiblePassword ? "eye.slash" : "eye")
                    }
                    .focused($focusedField, equals: .reveal)
                    .accessibilityLabel("Show or hide provider password")
                }
                TextField("Name (optional)", text: $name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .save }
                Button("Save provider") {
                    Task {
                        let saved = await model.addLocalProvider(name: name, provider: Provider(server: server, username: username, password: password), gateway: "")
                        if saved { password = ""; dismiss() }
                    }
                }
                .focused($focusedField, equals: .save)
                .buttonStyle(.card).tint(.white)
                .disabled(model.busy || server.isEmpty || username.isEmpty || password.isEmpty)
                if !model.notice.isEmpty { Text(model.notice).foregroundStyle(TVTheme.muted) }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .focusScope(addFocus)
        .defaultFocus($focusedField, .server)
        .background { StreamBackdrop() }
        .onAppear { focusedField = .server }
    }

}

extension TVSettingsView {
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            content()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: TVTheme.corner))
    }
}
