import SwiftUI

// Sign-in screen. Same account and vault as the iPhone build: sign in with
// the existing Rigatoni account and the saved provider populates automatically.
// Provider credentials themselves stay in the encrypted account vault and are
// never written to preferences, logs or disk caches.
struct TVLoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var createAccount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Rigatoni Stream")
                    .font(.largeTitle.weight(.bold))
                Text(createAccount ? "Create your account" : "Welcome back")
                    .font(.title.bold())
                Text("Your channels and movies, on the big screen.")
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
                Text("Use your existing Rigatoni account. Your provider login stays in the encrypted account vault.")
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

// Settings tab. Mirrors the iPhone build's SettingsView: provider + gateway
// preferences (saved through the shared encrypted vault), playback buffers,
// delete settings, sign out. No vault semantics were changed.
struct TVSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting = false
    @State private var visiblePassword = false
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                if let email = model.account.session?.user.email {
                    Text("Signed in as \(email)")
                        .foregroundStyle(TVTheme.muted)
                }

                settingsGroup(title: "Provider") {
                    Text(model.provider.requiresGateway
                         ? "Playback route: HTTPS gateway"
                         : "Playback route: direct provider")
                        .font(.footnote).foregroundStyle(TVTheme.muted)
                    TextField("Server URL", text: $model.provider.server)
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
                    TextField("HTTPS gateway URL (optional)", text: $model.gateway)
                    Text("Providers play directly when HTTPS or locally approved HTTP is available. Other HTTP hosts use your saved HTTPS gateway.")
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

                settingsGroup(title: "Account") {
                    HStack(spacing: 16) {
                        Button("Delete saved provider & gateway") { deleting = true }
                            .buttonStyle(.card).disabled(model.busy)
                        Button("Sign out") { Task { await model.signOut() } }
                            .buttonStyle(.card).disabled(model.busy)
                    }
                }

                Text("Rigatoni Stream 0.1 for tvOS · Native playback by VLCKit / VideoLAN (LGPL 2.1).")
                    .font(.footnote).foregroundStyle(TVTheme.muted)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .background { StreamBackdrop() }
        .confirmationDialog(
            "Delete your saved provider and gateway from your account?",
            isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Delete settings", role: .destructive) { Task { await model.deleteSettings() } }
        }
    }

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
