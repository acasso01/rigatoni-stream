import SwiftUI

@main
struct RigatoniStreamApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if model.starting { ProgressView("Opening Rigatoni Stream…") }
                else if model.signedIn {
                    TabView {
                        ForEach(LibraryKind.allCases) { kind in
                            LibraryView(kind: kind).tabItem { Label(kind.title, systemImage: kind.symbol) }
                        }
                    }
                    .sheet(isPresented: $model.settingsVisible) { SettingsView() }
                } else { LoginView() }
            }
            .environmentObject(model).tint(Color(red: 0.90, green: 0.035, blue: 0.08))
            .preferredColorScheme(.dark).task { await model.restore() }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var createAccount = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("🍝 RIGATONI").font(.largeTitle.weight(.black))
                    Text("STREAM").font(.largeTitle.weight(.black)).foregroundStyle(.red)
                    Text(createAccount ? "Create your account" : "Welcome back").font(.title.bold())
                    Text("Your TV and movies, in your pocket.").foregroundStyle(.secondary)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $password) }
                            else { SecureField("Password", text: $password) }
                        }.textContentType(createAccount ? .newPassword : .password)
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }.accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    Button(createAccount ? "Create account" : "Sign in") { Task { await authenticate() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
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
                    Text("Use your existing Rigatoni account. Your provider login stays in the encrypted account vault.").font(.footnote).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(28).padding(.top, 35)
            }.background(Color(red: 0.035, green: 0.035, blue: 0.045))
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
        } catch { model.notice = error.localizedDescription }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var visiblePassword = false
    @AppStorage("rigatoni-live-buffer-ms") private var liveBuffer = 1500
    @AppStorage("rigatoni-movie-buffer-ms") private var movieBuffer = 4000
    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Server URL", text: $model.provider.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $model.provider.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        if visiblePassword { TextField("Provider password", text: $model.provider.password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        else { SecureField("Provider password", text: $model.provider.password) }
                        Button { visiblePassword.toggle() } label: { Image(systemName: visiblePassword ? "eye.slash" : "eye") }.accessibilityLabel("Show or hide provider password")
                    }
                    TextField("HTTPS gateway URL (optional)", text: $model.gateway).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("HTTPS providers play directly. HTTP providers use your saved HTTPS gateway; connect Tailscale. VLC plays the original media.").font(.footnote).foregroundStyle(.secondary)
                    Button("Save provider & gateway") { Task { await model.saveSettings() } }.disabled(model.busy)
                    Button("Reload saved settings") { Task {
                        model.busy = true; defer { model.busy = false }
                        do { try await model.reloadSettings() } catch { model.notice = error.localizedDescription }
                    } }.disabled(model.busy)
                }
                Section("Playback buffer") {
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
                    Text("These buffers add delay. Streams retain their original resolution; HD and 4K playback depend on the source, device and connection.").font(.footnote).foregroundStyle(.secondary)
                }
                if !model.notice.isEmpty { Section { Text(model.notice).foregroundStyle(.secondary) } }
                Section {
                    Button("Delete saved provider & gateway", role: .destructive) { deleting = true }.disabled(model.busy)
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }.disabled(model.busy)
                }
                Section("About this test build") {
                    Text("Rigatoni Stream 0.1 · Native player powered by MobileVLCKit / VideoLAN (LGPL 2.1).")
                    Link("VideoLAN and VLCKit source", destination: URL(string: "https://code.videolan.org/videolan/VLCKit")!)
                }
            }
            .navigationTitle("Account & provider")
            .toolbar { Button("Done") { dismiss() }.disabled(model.busy) }
            .confirmationDialog("Delete your saved provider and gateway from your account?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete settings", role: .destructive) { Task { await model.deleteSettings() } }
            }
        }
    }
}
