import SwiftUI

struct CalendarSourcesView: View {
    @ObservedObject var connections: CalendarConnections
    let onConnect: () -> Void
    @State private var removing: ConnectedCalendarAccount?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your calendars").font(.headline)
                Spacer()
                IntegrationAction(title: "Connect account", enabled: !connections.isConnecting && connections.connectionBlockReason == nil, action: onConnect)
            }
            if let message = connections.errors["visibility"] {
                Text(message).font(.caption).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if let message = connections.connectionBlockReason {
                Text(message).font(.caption).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    feedToggle(id: "local", title: "Whytap · On this Mac")
                    if connections.appleEnabled {
                        Divider()
                        HStack {
                            Text("Apple Calendar").font(.headline)
                            Spacer()
                            IntegrationAction(title: "Disconnect", enabled: !connections.isConnecting && connections.connectionBlockReason == nil) {
                                guard !connections.isConnecting, connections.connectionBlockReason == nil else { return }
                                connections.disableApple()
                            }
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
                            IntegrationAction(title: "Disconnect", enabled: !connections.isConnecting && connections.connectionBlockReason == nil) { removing = account }
                        }
                        status(account.id.uuidString)
                        ForEach(connections.feeds.filter { $0.accountID == account.id }) { feed in
                            feedToggle(id: feed.id, title: feed.title)
                        }
                    }
                    if let message = connections.errors["accounts"] { Text(message).foregroundStyle(.orange) }
                }.padding(5) // Leave room for the external keyboard-focus ring inside the scroll clip.
            }
            Text("Connected calendars are read-only. Changes made in their own apps appear after refresh. Disconnection removes local sign-in; you can also revoke access in your provider’s account settings.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 410, height: 400)
        .alert("Disconnect calendar account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Disconnect", role: .destructive) {
                removing = nil
                guard connections.beginConnecting(provider: account.provider) else {
                    error = connections.connectionBlockReason ?? "Finish the other calendar operation first."
                    return
                }
                Task {
                    defer { connections.endConnecting() }
                    do { try await connections.remove(account) } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { _ in Text("Its events will disappear from Whytap. The original calendars and events stay with the provider.") }
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
    @State private var provider: CalendarProvider
    let allowsProviderSelection: Bool
    private let allowsAdvancedSetup: Bool
    private let compact: Bool
    private let onClose: (() -> Void)?
    private let configurationInfo: [String: Any]?
    @State private var label = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var working = false
    @State private var error: String?
    @State private var browser = CalendarBrowserSignIn()
    @State private var signInTask: Task<Void, Never>?
    @State private var showSetup = false
    private var registeredClient: CalendarClientConfiguration? { .registered(provider, info: configurationInfo) }
    private var readiness: CalendarConnectionReadiness { .authorization(provider, clientID: clientID, info: configurationInfo) }
    private var accountStorageAvailable: Bool { provider == .apple || connections.accountConnectionIssue == nil }

    init(connections: CalendarConnections, provider: CalendarProvider = .google,
         allowsProviderSelection: Bool = true, configurationInfo: [String: Any]? = Bundle.main.infoDictionary,
         compact: Bool = false, allowsAdvancedSetup: Bool? = nil, onClose: (() -> Void)? = nil) {
        self.connections = connections
        self._provider = State(initialValue: provider)
        self.allowsProviderSelection = allowsProviderSelection
        self.compact = compact
        self.allowsAdvancedSetup = allowsAdvancedSetup ?? allowsProviderSelection
        self.onClose = onClose
        self.configurationInfo = configurationInfo
        self._browser = State(initialValue: CalendarBrowserSignIn(configurationInfo: configurationInfo))
    }

    var body: some View {
        Group {
            if compact { compactBody } else { standardBody }
        }
        .onAppear { loadRegisteredClient() }
        .onChange(of: provider) { _, _ in loadRegisteredClient(); error = nil; showSetup = false }
        .onChange(of: clientID) { oldID, newID in
            clientSecret = CalendarClientConfiguration.secretAfterClientIDChange(from: oldID, to: newID,
                currentSecret: clientSecret, registered: registeredClient)
        }
        .onDisappear { signInTask?.cancel(); browser.cancel() }
    }

    private var canConnect: Bool {
        readiness == .available && accountStorageAvailable && connections.connectionBlockReason == nil &&
        !working && !connections.isConnecting && (provider == .apple || !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(provider.integrationTitle).font(.system(size: 13, weight: .semibold))
                Text(provider.permissionSummary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                if provider != .apple {
                    TextField("Account name (optional)", text: $label).textFieldStyle(.roundedBorder)
                        .modifier(CalendarHoverFieldFeedback()).disabled(working)
                    Text("Connects your calendar only. No Whytap account or app sign-in.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.76))
                    if allowsAdvancedSetup {
                        CalendarHoverButton { showSetup.toggle() } label: {
                            Label("Advanced app setup", systemImage: showSetup ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11)).padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(working).accessibilityValue(showSetup ? "Expanded" : "Collapsed")
                        if showSetup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("For source builds using your own provider registration.").font(.system(size: 11))
                                TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder)
                                    .modifier(CalendarHoverFieldFeedback()).disabled(working)
                                if provider == .google {
                                    SecureField("Desktop client secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                                        .modifier(CalendarHoverFieldFeedback()).disabled(working)
                                }
                                Text(setupText).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 6)
                        }
                    }
                }
                if let message = readiness.message ?? (provider == .apple ? nil : connections.accountConnectionIssue) {
                    Text(message).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = connections.connectionBlockReason {
                    Text(message).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.orange)
                }
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(provider == .apple ? "Allow access in the system prompt…" : "Finish connecting in your browser…")
                            .font(.system(size: 11))
                    }
                } else if connections.isConnecting {
                    Text("Finish the calendar connection already open.").font(.system(size: 11))
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.orange) }
                HStack(spacing: 8) {
                    IntegrationAction(title: "Cancel") { cancel() }
                    Spacer(minLength: 0)
                    IntegrationAction(title: provider == .apple ? "Allow access" : "Connect",
                        primary: true, enabled: canConnect) { connect() }
                }
                IntegrationLink(title: "Calendar privacy", destination: URL(string: "https://whytap.ai/calendar-privacy/")!)
                    .font(.system(size: 11))
            }.padding(3).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.visible)
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(allowsProviderSelection ? "Connect a calendar" : "Connect " + provider.integrationTitle).font(.title2.bold())
            Text("Bring your schedule together in Whytap.").foregroundStyle(MacSettingsTheme.text2)
            if allowsProviderSelection {
                Picker("Provider", selection: $provider) {
                    ForEach(CalendarProvider.allCases) { Text($0.title).tag($0) }
                }.disabled(working || connections.isConnecting)
            }
            Text(provider.permissionSummary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if provider != .apple {
                TextField("Account name (optional)", text: $label).textFieldStyle(.roundedBorder).disabled(working)
                if allowsProviderSelection && (registeredClient == nil || showSetup) {
                    TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder).disabled(working)
                    if provider == .google {
                        SecureField("Desktop client secret (if supplied by Google)", text: $clientSecret)
                            .textFieldStyle(.roundedBorder).disabled(working)
                    }
                }
                if allowsProviderSelection {
                    DisclosureGroup(registeredClient == nil ? "App setup" : "Advanced app setup", isExpanded: $showSetup) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(setupText).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("Redirect: http://\(provider == .microsoft ? "localhost" : "127.0.0.1")/callback (the port varies)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Text("Permissions: " + provider.scopes).font(.caption).textSelection(.enabled)
                            if let url = setupURL { IntegrationLink(title: "Open provider setup", destination: url) }
                        }.padding(.top, 8)
                    }
                }
                Text("Connect opens your browser to allow calendar access. No Whytap account or app sign-in is needed. Your password stays with the provider; access tokens are saved in Keychain.")
                    .font(.caption).foregroundStyle(MacSettingsTheme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if let message = readiness.message {
                Text(message).font(.callout).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider != .apple, let message = connections.accountConnectionIssue {
                Text(message).font(.callout).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = connections.connectionBlockReason {
                Text(message).font(.callout).foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if connections.isConnecting && !working {
                Text("Finish the calendar sign-in already open in another window.")
                    .font(.callout).foregroundStyle(MacSettingsTheme.orange)
            }
            if working { HStack { ProgressView().controlSize(.small); Text("Finish sign-in in your browser…").font(.callout) } }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                IntegrationLink(title: "Calendar privacy", destination: URL(string: "https://whytap.ai/calendar-privacy/")!)
                    .font(.caption)
                Spacer()
                IntegrationAction(title: "Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                IntegrationAction(title: provider == .apple ? "Allow calendar access" : "Connect",
                    primary: true, enabled: canConnect) { connect() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func cancel() { signInTask?.cancel(); browser.cancel(); close() }

    private func loadRegisteredClient() {
        clientID = registeredClient?.clientID ?? ""
        clientSecret = registeredClient?.clientSecret ?? ""
    }

    private var setupText: String {
        switch provider {
        case .google: return "Create a Desktop app OAuth client in Google Cloud, enable Calendar API, and configure the consent screen. For a testing app, add your Google account as a test user. Paste the client ID and desktop client secret here."
        case .microsoft: return "Register an app in Microsoft Entra with personal and work accounts enabled. Add a Mobile and desktop redirect for http://localhost/callback. Enable delegated Calendars.Read and offline_access. Browser sign-in uses PKCE; leave the additional Allow public client flows setting disabled. Your organization may require administrator approval. No client secret is needed."
        case .zoom: return "Create a General app in Zoom Marketplace. Enable Use public client OAuth; set PKCE OAuth Redirect URL and OAuth allow list to http://127.0.0.1/callback. Use its public client ID and the listed read scopes. Zoom Calendar Service must be available for the account."
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
        guard readiness == .available, accountStorageAvailable, !working, connections.beginConnecting(provider: provider) else { return }
        working = true; error = nil
        let chosenProvider = provider
        let chosenID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenSecret = clientSecret
        let chosenLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        signInTask = Task {
            defer { working = false; connections.endConnecting() }
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
                if compact { NSApp.activate(ignoringOtherApps: true) }
                close()
            } catch is CancellationError { }
            catch { self.error = (error as? CalendarConnectionError)?.localizedDescription ?? "Couldn’t connect the calendar. Try again." }
        }
    }
}
