import SwiftUI

struct CalendarSourcesView: View {
    @ObservedObject var connections: CalendarConnections
    let onConnect: () -> Void
    @State private var removing: ConnectedCalendarAccount?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your calendars").font(.headline); Spacer(); Button("Connect account", action: onConnect) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    feedToggle(id: "local", title: "Whytap · On this Mac")
                    if connections.appleEnabled {
                        Divider()
                        HStack {
                            Text("Apple Calendar").font(.headline)
                            Spacer()
                            Button("Disconnect") { connections.disableApple() }
                        }
                        status("apple")
                        ForEach(connections.feeds.filter { $0.provider == .apple }) { feed in
                            feedToggle(id: feed.id, title: feed.title)
                        }
                    }
                    ForEach(connections.accounts) { account in
                        Divider()
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.label).font(.headline)
                                Text(account.provider.title).font(.caption).foregroundStyle(MacSettingsTheme.text2)
                            }
                            Spacer()
                            Button("Disconnect") { removing = account }
                        }
                        status(account.id.uuidString)
                        ForEach(connections.feeds.filter { $0.accountID == account.id }) { feed in
                            feedToggle(id: feed.id, title: feed.title)
                        }
                    }
                    if let message = connections.errors["accounts"] { Text(message).foregroundStyle(.orange) }
                }
            }
            Text("Connected calendars are read-only. Changes made in their own apps appear after refresh. Disconnection removes local sign-in; you can also revoke access in your provider’s account settings.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 410, height: 400)
        .alert("Disconnect calendar account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Disconnect", role: .destructive) {
                guard let account = removing else { return }
                removing = nil
                Task { do { try await connections.remove(account) } catch { self.error = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Its events will disappear from Whytap. The original calendars and events stay with the provider.") }
    }

    private func feedToggle(id: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { !connections.hiddenFeeds.contains(id) },
            set: { connections.setVisible($0, feedID: id) })).toggleStyle(.checkbox)
    }
    @ViewBuilder private func status(_ key: String) -> some View {
        if let error = connections.errors[key] { Text(error).font(.caption).foregroundStyle(.orange) }
        else if let date = connections.lastSynced[key] {
            Text("Updated " + date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(MacSettingsTheme.text2)
        } else { Text("Waiting for first sync").font(.caption).foregroundStyle(MacSettingsTheme.text2) }
    }
}

struct CalendarConnectView: View {
    @ObservedObject var connections: CalendarConnections
    @Environment(\.dismiss) private var dismiss
    @State private var provider: CalendarProvider = .google
    @State private var label = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var working = false
    @State private var error: String?
    @State private var browser = CalendarBrowserSignIn()
    @State private var signInTask: Task<Void, Never>?
    @State private var showSetup = false
    private var registeredClient: CalendarClientConfiguration? { .registered(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect a calendar").font(.title2.bold())
            Text("Bring your schedule together in Whytap.").foregroundStyle(MacSettingsTheme.text2)
            Picker("Provider", selection: $provider) {
                ForEach(CalendarProvider.allCases) { Text($0.title).tag($0) }
            }.disabled(working)
            if provider == .apple {
                Text("Allow Whytap to show calendars available on your Mac, including iCloud. Google, Outlook and Zoom can connect separately here without being added to macOS.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("macOS requests full calendar permission to allow reading. Whytap uses this connection only to display events.")
                    .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            } else {
                TextField("Account name (optional)", text: $label).textFieldStyle(.roundedBorder).disabled(working)
                if registeredClient == nil || showSetup {
                    TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder).disabled(working)
                    if provider == .google {
                        SecureField("Desktop client secret (if supplied by Google)", text: $clientSecret)
                            .textFieldStyle(.roundedBorder).disabled(working)
                    }
                }
                DisclosureGroup(registeredClient == nil ? "App setup" : "Advanced app setup", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(setupText).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Redirect: http://\(provider == .microsoft ? "localhost" : "127.0.0.1")/callback (the port varies)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("Permissions: " + provider.scopes).font(.caption).textSelection(.enabled)
                        if let url = setupURL { Link("Open provider setup", destination: url) }
                    }.padding(.top, 8)
                }
                Text("Sign-in opens your browser. Whytap receives calendar access; your account password stays with the provider. Tokens are saved in Keychain.")
                    .font(.caption).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if working { HStack { ProgressView().controlSize(.small); Text("Finish sign-in in your browser…").font(.callout) } }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Link("Calendar privacy", destination: URL(string: "https://whytap.ai/calendar-privacy/")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { signInTask?.cancel(); browser.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(provider == .apple ? "Allow calendar access" : "Sign in") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || (provider != .apple && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(26).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadRegisteredClient() }
        .onChange(of: provider) { _, _ in loadRegisteredClient(); error = nil; showSetup = false }
        .onDisappear { signInTask?.cancel(); browser.cancel() }
    }

    private func loadRegisteredClient() {
        clientID = registeredClient?.clientID ?? ""
        clientSecret = registeredClient?.clientSecret ?? ""
    }

    private var setupText: String {
        switch provider {
        case .google: return "Create a Desktop app OAuth client in Google Cloud, enable Calendar API, and configure the consent screen. For a testing app, add your Google account as a test user. Paste the client ID and desktop client secret here."
        case .microsoft: return "Register an app in Microsoft Entra with personal and work accounts enabled. Add a Mobile and desktop redirect for http://localhost/callback and allow public client flows. Enable the delegated Calendars.Read permission. Your organization may require administrator approval. No client secret is needed."
        case .zoom: return "Create a General app in Zoom Marketplace. Enable Public Client OAuth and PKCE, and register http://127.0.0.1/callback in the OAuth allow list. Use the public client ID and enable the listed calendar read scopes. Zoom Calendar Service must be available for the account."
        case .apple: return ""
        }
    }
    private var setupURL: URL? {
        switch provider {
        case .google: return URL(string: "https://console.cloud.google.com/auth/clients")
        case .microsoft: return URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")
        case .zoom: return URL(string: "https://marketplace.zoom.us/develop/create")
        case .apple: return nil
        }
    }
    private func connect() {
        working = true; error = nil
        let chosenProvider = provider
        let chosenID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenSecret = clientSecret
        let chosenLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        signInTask = Task {
            defer { working = false }
            do {
                if chosenProvider == .apple { try await connections.enableApple() }
                else {
                    let id = UUID()
                    let verifier = try CalendarPKCE.random()
                    let state = try CalendarPKCE.random()
                    let result = try await browser.authorize(provider: chosenProvider, clientID: chosenID, state: state, verifier: verifier)
                    try await connections.oauth.connect(provider: chosenProvider, clientID: chosenID, clientSecret: chosenSecret,
                        code: result.code, redirect: result.redirect, verifier: verifier, id: id)
                    do {
                        try Task.checkCancellation()
                        try connections.add(ConnectedCalendarAccount(id: id, provider: chosenProvider,
                            label: chosenLabel.isEmpty ? chosenProvider.title : String(chosenLabel.prefix(120))))
                    } catch { try? await connections.oauth.disconnect(id); throw error }
                }
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError { }
            catch { self.error = (error as? CalendarConnectionError)?.localizedDescription ?? "Couldn’t connect the calendar. Try again." }
        }
    }
}
