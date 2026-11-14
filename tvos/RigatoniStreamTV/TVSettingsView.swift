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
                Text("Optional. Syncs a provider with your Ant Streams account and unlocks the HTTPS gateway.")
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
            do { try await model.reloadSettings() }
            catch { model.notice = "Signed in. \(error.localizedDescription)" }
        } catch { model.notice = error.localizedDescription }
    }
}

// First launch, when no provider is saved and nobody is signed in.
// Focus lands on Server URL, matching Settings.
struct TVProviderSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var setupFocus
    @FocusState private var serverFocused: Bool
    @State private var visiblePassword = false
    @State private var showAccount = false

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
                        TextField("Server URL", text: $model.provider.server)
                            .focused($serverFocused)
                            .prefersDefaultFocus(in: setupFocus)
                        TextField("Username", text: $model.provider.username)
                        HStack {
                            Group {
                                if visiblePassword { TextField("Provider password", text: $model.provider.password) }
                                else { SecureField("Provider password", text: $model.provider.password) }
                            }
                            Button { visiblePassword.toggle() } label: {
                                Image(systemName: visiblePassword ? "eye.slash" : "eye")
                            }
                            .accessibilityLabel("Show or hide provider password")
                        }
                        TextField("Name (optional)", text: $model.providerName)
                        Button("Start watching") { Task { await model.saveSettings() } }
                            .buttonStyle(.card)
                            .tint(.white)
                            .disabled(model.busy || model.provider.server.isEmpty || model.provider.username.isEmpty || model.provider.password.isEmpty)
                        Button("Sign in to sync") { showAccount = true }
                            .buttonStyle(.card)
                        if model.busy { ProgressView() }
                        if !model.notice.isEmpty {
                            Text(model.notice).font(.callout).foregroundStyle(TVTheme.muted)
                        }
                        Text("The provider login is saved in this device's Keychain only. Direct providers play immediately. The HTTPS gateway is in Settings and needs an Ant Streams sign-in.")
                            .font(.footnote)
                            .foregroundStyle(TVTheme.muted)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(60)
                }
                .focusScope(setupFocus)
                .defaultFocus($serverFocused, true)
            }
        }
        .background { StreamBackdrop() }
        .onAppear { serverFocused = true }
        .onChange(of: showAccount) { _, showing in
            if !showing { serverFocused = true }
        }
    }
}

// Settings tab. Provider fields are saved on this device unless an account
// session is active, in which case Save still writes the encrypted vault.
// Right from the nav rail lands on Server URL.
struct TVSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("rigatoni-appearance") private var appearance = "dark"
    @State private var deleting = false
    @State private var visiblePassword = false
    @State private var pendingRemoval: String?
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000

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
                        NavigationLink("Themes & hidden categories / channels") { LibraryCustomizationView() }
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                    }
                    settingsGroup(title: "Provider") {
                        Text(model.provider.requiresGateway
                             ? (model.signedIn ? "Playback route: HTTPS gateway" : "Playback route: HTTPS gateway — sign in required. Direct providers still play.")
                             : "Playback route: direct provider")
                            .font(.footnote).foregroundStyle(TVTheme.muted)
                        TVEntryControl(section: .settings) {
                            TextField("Server URL", text: $model.provider.server)
                                .tvContentEntry()
                        }
                        TextField("Username", text: $model.provider.username)
                        HStack {
                            Group {
                                if visiblePassword { TextField("Provider password", text: $model.provider.password) }
                                else { SecureField("Provider password", text: $model.provider.password) }
                            }
                            Button { visiblePassword.toggle() } label: {
                                Image(systemName: visiblePassword ? "eye.slash" : "eye")
                            }
                            .accessibilityLabel("Show or hide provider password")
                        }
                        TextField("Name (optional)", text: $model.providerName)
                        TextField("HTTPS gateway URL (optional)", text: $model.gateway)
                        Text(model.signedIn
                             ? "Providers play directly when HTTPS or HTTP is available. Other playback can use your saved HTTPS gateway."
                             : "Direct providers play without an account. The HTTPS gateway needs an Ant Streams sign-in and does not block a direct provider.")
                            .font(.footnote).foregroundStyle(TVTheme.muted)
                        HStack(spacing: 16) {
                            Button("Save provider & gateway") { Task { await model.saveSettings() } }
                                .buttonStyle(.card).tint(.white).disabled(model.busy)
                            Button("Reload saved settings") {
                                Task {
                                    model.busy = true; defer { model.busy = false }
                                    do { try await model.reloadSettings() }
                                    catch { model.notice = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.card).disabled(model.busy)
                        }
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
                            Text("Provider settings sync to your Ant Streams account. The HTTPS gateway uses this sign-in.")
                                .font(.footnote).foregroundStyle(TVTheme.muted)
                        } else {
                            Text("Optional. Sign in to copy this provider to your Ant Streams account and to use the HTTPS gateway. Direct providers work without an account.")
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
        }
    }

}

private struct TVAddProviderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Namespace private var addFocus
    @FocusState private var serverFocused: Bool
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
                    .focused($serverFocused)
                    .prefersDefaultFocus(in: addFocus)
                TextField("Username", text: $username)
                HStack {
                    Group {
                        if visiblePassword { TextField("Provider password", text: $password) }
                        else { SecureField("Provider password", text: $password) }
                    }
                    Button { visiblePassword.toggle() } label: {
                        Image(systemName: visiblePassword ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel("Show or hide provider password")
                }
                TextField("Name (optional)", text: $name)
                Button("Save provider") {
                    Task {
                        let saved = await model.addLocalProvider(name: name, provider: Provider(server: server, username: username, password: password), gateway: "")
                        if saved { password = ""; dismiss() }
                    }
                }
                .buttonStyle(.card).tint(.white)
                .disabled(model.busy || server.isEmpty || username.isEmpty || password.isEmpty)
                if !model.notice.isEmpty { Text(model.notice).foregroundStyle(TVTheme.muted) }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .focusScope(addFocus)
        .defaultFocus($serverFocused, true)
        .background { StreamBackdrop() }
        .onAppear { serverFocused = true }
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
