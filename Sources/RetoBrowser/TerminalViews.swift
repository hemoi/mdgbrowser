import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

struct TerminalLauncherButton: View {
    @Environment(BrowserTheme.self) private var theme

    let store: TerminalWorkspaceStore

    var body: some View {
        Button {
            store.toggleSurface()
        } label: {
            Image(systemName: store.presentedSurface == nil ? "terminal" : "terminal.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(theme.border, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.presentedSurface == nil ? "Open terminal" : "Hide terminal")
        .accessibilityIdentifier("terminal.launcher")
    }
}

struct FloatingTerminalWindow: View {
    @State private var restingOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var resizeStartSize: CGSize?
    // Persisted so the window keeps its size across sessions; 0 = default.
    @AppStorage("reto-terminal.floating-width") private var storedWidth = 0.0
    @AppStorage("reto-terminal.floating-height") private var storedHeight = 0.0

    let store: TerminalWorkspaceStore

    private static let minPanelSize = CGSize(width: 340, height: 260)

    var body: some View {
        GeometryReader { geometry in
            let panelSize = panelSize(in: geometry.size)
            let currentOffset = clampedOffset(
                CGSize(
                    width: restingOffset.width + dragOffset.width,
                    height: restingOffset.height + dragOffset.height
                ),
                panelSize: panelSize,
                containerSize: geometry.size
            )

            TerminalPanel(store: store, dragGesture: dragGesture(panelSize: panelSize, containerSize: geometry.size))
                .frame(width: panelSize.width, height: panelSize.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
                }
                .overlay(alignment: .bottomTrailing) {
                    resizeHandle(containerSize: geometry.size)
                }
                .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .offset(currentOffset)
        }
        .padding(8)
        .accessibilityIdentifier("terminal.floating-window")
    }

    private func panelSize(in containerSize: CGSize) -> CGSize {
        let maxWidth = max(containerSize.width - 24, 1)
        let maxHeight = max(containerSize.height - 80, 1)
        let defaultWidth = min(760, maxWidth)
        let defaultHeight = min(540, maxHeight)
        let width = storedWidth > 0 ? min(max(storedWidth, Self.minPanelSize.width), maxWidth) : defaultWidth
        let height = storedHeight > 0 ? min(max(storedHeight, Self.minPanelSize.height), maxHeight) : defaultHeight
        // Whole points: fractional sizes make the terminal re-rasterize on
        // every layout pass while the keyboard animates.
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func resizeHandle(containerSize: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeStartSize == nil {
                            resizeStartSize = panelSize(in: containerSize)
                        }
                        guard let start = resizeStartSize else { return }
                        storedWidth = min(
                            max(start.width + value.translation.width, Self.minPanelSize.width),
                            max(containerSize.width - 24, Self.minPanelSize.width)
                        )
                        storedHeight = min(
                            max(start.height + value.translation.height, Self.minPanelSize.height),
                            max(containerSize.height - 80, Self.minPanelSize.height)
                        )
                    }
                    .onEnded { _ in resizeStartSize = nil }
            )
            .accessibilityLabel("Resize terminal window")
            .accessibilityIdentifier("terminal.resize")
    }

    private func dragGesture(panelSize: CGSize, containerSize: CGSize) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 2)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    restingOffset = clampedOffset(
                        CGSize(
                            width: restingOffset.width + value.translation.width,
                            height: restingOffset.height + value.translation.height
                        ),
                        panelSize: panelSize,
                        containerSize: containerSize
                    )
                }
        )
    }

    private func clampedOffset(
        _ proposed: CGSize,
        panelSize: CGSize,
        containerSize: CGSize
    ) -> CGSize {
        let horizontalLimit = max((containerSize.width - panelSize.width) / 2 - 12, 0)
        let verticalLimit = max((containerSize.height - panelSize.height) / 2 - 12, 0)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }
}

struct TerminalPanel: View {
    @Environment(BrowserTheme.self) private var theme

    let store: TerminalWorkspaceStore
    var dragGesture: AnyGesture<DragGesture.Value>?

    private var isPhoneSheet: Bool {
        dragGesture == nil && UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            terminalHeader
            Rectangle().fill(theme.border).frame(height: 0.5)
            terminalContent
        }
        .background {
            // On the iPhone sheet presentation the panel's own background
            // otherwise stops above the home-indicator safe area, leaving a
            // seam where the sheet's presentation background shows through.
            // Extend the fill through the bottom safe area so the panel
            // reads as one continuous surface; the VStack above is left
            // alone so its content (tab bar, terminal, empty state) still
            // lays out above the home indicator.
            theme.background.ignoresSafeArea(edges: isPhoneSheet ? .bottom : [])
        }
        .sheet(item: $store.presentedSheet) { destination in
            switch destination {
            case .profiles:
                SSHProfilesSheet(store: store)
                    .environment(theme)
            case .profileEditor(let profile):
                SSHProfileEditor(profile: profile, store: store)
                    .environment(theme)
            case .tmuxSessions:
                TmuxSessionBrowserSheet(store: store)
                    .environment(theme)
            }
        }
        .alert(item: $store.pendingHostTrust) { request in
            hostTrustAlert(request)
        }
        .alert(
            "SSH Profile Storage",
            isPresented: Binding(
                get: { store.storageErrorMessage != nil },
                set: { if !$0 { store.dismissStorageError() } }
            )
        ) {
            Button("OK", role: .cancel) { store.dismissStorageError() }
        } message: {
            Text(store.storageErrorMessage ?? "Unknown Keychain error")
        }
        .onDisappear {
            store.selectedTab?.dismissKeyboard()
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: 6) {
            if let dragGesture {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .accessibilityLabel("Move terminal window")
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 28, height: 40)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        terminalTab(tab)
                    }
                }
            }
            .scrollIndicators(.hidden)

            terminalAddMenu

            if !store.profiles.isEmpty {
                CompactIconButton(systemName: "rectangle.stack", accessibilityLabel: "Browse tmux sessions") {
                    store.presentedSheet = .tmuxSessions
                }
                .accessibilityIdentifier("terminal.tmux-sessions")
            }

            CompactIconButton(systemName: "gearshape", accessibilityLabel: "Manage SSH profiles") {
                store.presentedSheet = .profiles
            }

            if isPhoneSheet, store.selectedTab != nil {
                CompactIconButton(
                    systemName: "keyboard.chevron.compact.down",
                    accessibilityLabel: "Hide terminal keyboard"
                ) {
                    store.selectedTab?.dismissKeyboard()
                }
                .accessibilityIdentifier("terminal.hide-keyboard")
            }

            CompactIconButton(
                systemName: isPhoneSheet ? "chevron.down" : "xmark",
                accessibilityLabel: isPhoneSheet ? "Dismiss terminal" : "Close terminal"
            ) {
                store.selectedTab?.dismissKeyboard()
                store.presentedSurface = nil
            }
            .accessibilityIdentifier("terminal.dismiss")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(theme.raisedBackground)
    }

    private func terminalTab(_ tab: TerminalSession) -> some View {
        let selected = tab.id == store.selectedTab?.id
        return HStack(spacing: 0) {
            Button {
                store.selectTab(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(tab.state))
                        .frame(width: 6, height: 6)

                    Text(tab.title)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 22, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(selected ? theme.background : theme.label)
        .padding(.leading, 9)
        .frame(width: isPhoneSheet ? 138 : 170, height: 28)
        .background(selected ? theme.accent : theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            if !selected {
                RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 0.75)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.tab.\(tab.id.uuidString)")
    }

    private var terminalAddMenu: some View {
        Menu {
            if store.profiles.isEmpty {
                Button("Add SSH Profile", systemImage: "server.rack") {
                    store.presentedSheet = .profiles
                }
            } else {
                ForEach(store.profiles) { profile in
                    Button {
                        store.openTab(profileID: profile.id)
                    } label: {
                        Label(profile.displayName, systemImage: profile.usesTmux ? "rectangle.stack" : "server.rack")
                    }
                }

                Divider()

                Button("Browse tmux Sessions", systemImage: "rectangle.stack") {
                    store.presentedSheet = .tmuxSessions
                }

                Button("Manage Profiles", systemImage: "gearshape") {
                    store.presentedSheet = .profiles
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New terminal tab")
        .accessibilityIdentifier("terminal.new-tab")
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let tab = store.selectedTab {
            VStack(spacing: 0) {
                TerminalConnectionStatusBar(tab: tab)
                TerminalEmulatorRepresentable(session: tab)
                    .id(tab.id)
            }
        } else {
            TerminalEmptyState(store: store)
        }
    }

    private func statusColor(_ state: TerminalConnectionState) -> SwiftUI.Color {
        switch state {
        case .connecting:
            .orange
        case .connected:
            theme.tailnet
        case .suspended:
            .orange
        case .disconnected:
            theme.mutedLabel
        case .failed:
            .red
        }
    }

    private func hostTrustAlert(_ request: HostTrustRequest) -> Alert {
        TerminalHostTrustAlert.alert(for: request, store: store)
    }
}

/// Shared host-trust alert so the terminal panel and the tmux session browser
/// present identical wording for the same request.
@MainActor
enum TerminalHostTrustAlert {
    static func alert(for request: HostTrustRequest, store: TerminalWorkspaceStore) -> Alert {
        let title = request.hostKeyChanged ? "SSH Host Key Changed" : "Trust SSH Host?"
        let explanation = request.hostKeyChanged
            ? "The host key for \(request.host) differs from the saved key. Only continue if the server key was intentionally replaced."
            : "Verify this fingerprint with the server administrator before connecting to \(request.host)."
        let fingerprints: String
        if let expectedFingerprint = request.expectedFingerprint {
            fingerprints = "Saved: \(expectedFingerprint)\nPresented: \(request.presentedFingerprint)"
        } else {
            fingerprints = request.presentedFingerprint
        }
        let message = "\(explanation)\n\n\(fingerprints)"
        let acceptTitle = request.hostKeyChanged ? "Replace & Connect" : "Trust & Connect"

        return Alert(
            title: Text(title),
            message: Text(message),
            primaryButton: request.hostKeyChanged
                ? .destructive(Text(acceptTitle)) { store.resolveHostTrust(request, accept: true) }
                : .default(Text(acceptTitle)) { store.resolveHostTrust(request, accept: true) },
            secondaryButton: .cancel { store.resolveHostTrust(request, accept: false) }
        )
    }
}

private struct TerminalConnectionStatusBar: View {
    @Environment(BrowserTheme.self) private var theme

    let tab: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            if tab.state == .connecting {
                ProgressView().controlSize(.mini)
            }

            Text(tab.state.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.mutedLabel)

            Text(tab.profile.endpoint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.mutedLabel)
                .lineLimit(1)

            Spacer()

            if case .failed = tab.state {
                Button("Retry") { tab.connect() }
                    .font(.system(size: 10, weight: .semibold))
            } else if tab.state == .disconnected || tab.state == .suspended {
                Button("Reconnect") { tab.connect() }
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.raisedBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }
}

private struct TerminalEmptyState: View {
    @Environment(BrowserTheme.self) private var theme

    let store: TerminalWorkspaceStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.mutedLabel)

            VStack(spacing: 4) {
                Text("No Terminal Tabs")
                    .font(.system(size: 16, weight: .semibold))
                Text("Open a saved SSH profile to start a remote shell.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.mutedLabel)
                    .multilineTextAlignment(.center)
            }

            if store.profiles.isEmpty {
                Button("Add SSH Profile", systemImage: "plus") {
                    store.presentedSheet = .profiles
                }
                .primaryActionStyle(theme)
                .accessibilityIdentifier("terminal.empty.add-profile")
            } else {
                Menu("Open SSH Profile", systemImage: "server.rack") {
                    ForEach(store.profiles) { profile in
                        Button(profile.displayName) { store.openTab(profileID: profile.id) }
                    }
                }
                .primaryActionStyle(theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(theme.background)
    }
}

private struct TerminalEmulatorRepresentable: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> RetoTerminalView {
        let view = session.terminalView
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RetoTerminalView, context: Context) {}
}

struct SSHProfilesSheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var editingProfile: SSHProfile?

    let store: TerminalWorkspaceStore

    var body: some View {
        NavigationStack {
            Group {
                if store.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No SSH Profiles", systemImage: "server.rack")
                    } description: {
                        Text("Connection details and passwords are stored only in this device’s Keychain.")
                    } actions: {
                        Button("Add Profile") { editingProfile = SSHProfile() }
                            .primaryActionStyle(theme)
                            .accessibilityIdentifier("terminal.profiles.add-empty")
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.profiles) { profile in
                                Button {
                                    store.openTab(profileID: profile.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: profile.usesTmux ? "rectangle.stack" : "server.rack")
                                            .foregroundStyle(profile.usesTmux ? theme.tailnet : theme.mutedLabel)
                                            .frame(width: 22)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(profile.displayName)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(theme.label)
                                            Text(profile.endpoint)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(theme.mutedLabel)
                                        }

                                        Spacer()

                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(theme.mutedLabel)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        store.deleteProfile(profile.id)
                                    }
                                    Button("Edit", systemImage: "pencil") {
                                        editingProfile = profile
                                    }
                                    .tint(theme.tailnet)
                                }
                                .contextMenu {
                                    Button("Edit", systemImage: "pencil") { editingProfile = profile }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        store.deleteProfile(profile.id)
                                    }
                                }
                            }
                        } footer: {
                            Text("Passwords and trusted host fingerprints are encrypted by the iOS Keychain and do not migrate to another device.")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(theme.background)
                }
            }
            .navigationTitle("SSH Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { editingProfile = SSHProfile() }
                        .accessibilityIdentifier("terminal.profiles.add")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            SSHProfileEditor(profile: profile, store: store)
                .environment(theme)
        }
    }
}

/// Resolves the SSH profile editor's port text field to a concrete port
/// number. Kept free of view state so it can be unit tested directly.
enum SSHPortField {
    /// Default port used whenever the field is left blank or holds text that
    /// doesn't parse to a valid port.
    static let defaultPort = 22

    static func resolvedPort(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), (1...65_535).contains(parsed) else {
            return defaultPort
        }
        return parsed
    }
}

struct SSHProfileEditor: View {
    private enum FocusField: Hashable {
        case name
        case host
        case port
        case username
        case password
        case privateKeyPassphrase
        case tmuxSession
    }

    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SSHProfile
    @State private var portText: String
    @State private var importingPrivateKey = false
    @State private var keyImportError: String?
    @FocusState private var focusedField: FocusField?

    let store: TerminalWorkspaceStore

    init(profile: SSHProfile, store: TerminalWorkspaceStore) {
        _profile = State(initialValue: profile)
        // A non-optional Int always has a value, so a freshly created profile
        // (whose port already defaults to 22) would otherwise show "22" as
        // if the user had typed it. Show it blank instead and let the
        // placeholder communicate the default.
        _portText = State(initialValue: profile.port == SSHPortField.defaultPort ? "" : String(profile.port))
        self.store = store
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .host }

                    TextField("Host or IP address", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }

                    TextField("Port", text: $portText, prompt: Text("Port 22 if left empty"))
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .onChange(of: portText) {
                            profile.port = SSHPortField.resolvedPort(from: portText)
                        }
                }

                Section {
                    TextField("Username", text: $profile.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = profile.authenticationKind == .password ? .password : .privateKeyPassphrase
                        }

                    Picker("Method", selection: $profile.authenticationKind) {
                        ForEach(SSHAuthenticationKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if profile.authenticationKind == .password {
                        SecureField("Password", text: $profile.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                    } else {
                        if profile.privateKey.isEmpty {
                            Button("Import OpenSSH Private Key", systemImage: "key") {
                                importingPrivateKey = true
                            }
                        } else {
                            Label("Private key imported", systemImage: "checkmark.shield")
                                .foregroundStyle(.green)
                            Button("Replace Private Key", systemImage: "arrow.triangle.2.circlepath") {
                                importingPrivateKey = true
                            }
                            Button("Remove Private Key", role: .destructive) {
                                profile.privateKey = ""
                                profile.privateKeyPassphrase = ""
                            }
                        }

                        SecureField("Key passphrase (optional)", text: $profile.privateKeyPassphrase)
                            .textContentType(.password)
                            .focused($focusedField, equals: .privateKeyPassphrase)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Passwords, keys, and passphrases are stored in a device-only Keychain item. Password login also tries keyboard-interactive authentication with the saved password. MFA/OTP prompts that require a separate response are not supported.")
                }

                Section {
                    Toggle("Attach or create a tmux session", isOn: $profile.usesTmux)

                    if profile.usesTmux {
                        TextField("Session name", text: $profile.tmuxSession)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .tmuxSession)
                    }
                } header: {
                    Text("tmux")
                } footer: {
                    Text("Uses tmux -u new-session -A so the session survives disconnects and stays UTF-8 aware.")
                }

                if let fingerprint = profile.hostKeyFingerprint {
                    Section {
                        Text(fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)

                        Button("Forget Host Key", role: .destructive) {
                            profile.hostKeyFingerprint = nil
                        }
                    } header: {
                        Text("Trusted Host Key")
                    } footer: {
                        Text("You will be asked to verify the server fingerprint on the next connection.")
                    }
                }

                if let validationMessage = profile.validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.raisedBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(profile.name.isEmpty ? "New SSH Profile" : "Edit SSH Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.port = SSHPortField.resolvedPort(from: portText)
                        if store.saveProfile(profile) {
                            dismiss()
                        }
                    }
                    .disabled(profile.validationMessage != nil)
                    .accessibilityIdentifier("terminal.profile.save")
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear {
                focusedField = profile.host.isEmpty ? .host : .name
            }
        }
        .presentationDetents([.large])
        .fileImporter(
            isPresented: $importingPrivateKey,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                profile.privateKey = try String(contentsOf: url, encoding: .utf8)
            } catch {
                keyImportError = error.localizedDescription
            }
        }
        .alert(
            "Couldn’t Import Key",
            isPresented: Binding(
                get: { keyImportError != nil },
                set: { if !$0 { keyImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { keyImportError = nil }
        } message: {
            Text(keyImportError ?? "Unknown error")
        }
    }
}
