import Observation
import SwiftTerm
import SwiftUI
import UIKit

@MainActor
final class RetoTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((_ cols: Int, _ rows: Int, _ pixelWidth: Int, _ pixelHeight: Int) -> Void)?
    var onTitleChange: ((String) -> Void)?

    static func resyllabifyKoreanForTesting(base: Character, followingVowel: Character) -> String? {
        SwiftTerm.SwiftTermHangulInput.resyllabifyFinalConsonant(
            base: base,
            followingVowel: followingVowel
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        optionAsMetaKey = false
        allowMouseReporting = true
        accessibilityIdentifier = "terminal.emulator"
        apply(TerminalPreferences())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ preferences: TerminalPreferences) {
        let size = CGFloat(preferences.fontSize)
        font = preferences.font.font(size: size)
        nativeBackgroundColor = preferences.theme.backgroundColor
        nativeForegroundColor = preferences.theme.foregroundColor
        caretColor = preferences.theme.cursorColor
        selectedTextBackgroundColor = preferences.theme.cursorColor.withAlphaComponent(0.35)
        installColors(preferences.theme.swiftTermPalette)

        if let accessory = inputAccessoryView as? RetoTerminalAccessoryView {
            accessory.configure(groups: preferences.hotkeyGroups)
        } else {
            inputAccessoryView = RetoTerminalAccessoryView(
                terminalView: self,
                groups: preferences.hotkeyGroups
            )
        }
        if isFirstResponder {
            reloadInputViews()
        }
        setNeedsDisplay()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        onResize?(
            newCols,
            newRows,
            Int(bounds.width * scale),
            Int(bounds.height * scale)
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
@Observable
final class TerminalSession: Identifiable {
    typealias HostKeyApproval = @Sendable (_ fingerprint: String, _ expectedFingerprint: String?) async -> Bool

    let id: UUID
    var profile: SSHProfile
    var state: TerminalConnectionState = .connecting
    var terminalTitle: String = ""

    /// Set when this tab attaches a discovered tmux session rather than the
    /// profile's fixed one.
    @ObservationIgnored let tmuxAttach: TmuxAttachIntent?
    @ObservationIgnored let terminalView: RetoTerminalView
    @ObservationIgnored private var engine: any SSHConnectionEngineProtocol = SSHConnectionEngine()
    @ObservationIgnored private let approveHostKey: HostKeyApproval
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput: [UInt8] = []
    @ObservationIgnored private var connectionAttemptID = UUID()
    @ObservationIgnored private var wantsConnection = true

    init(
        id: UUID = UUID(),
        profile: SSHProfile,
        tmuxAttach: TmuxAttachIntent? = nil,
        preferences: TerminalPreferences = TerminalPreferences(),
        approveHostKey: @escaping HostKeyApproval
    ) {
        self.id = id
        self.profile = profile
        self.tmuxAttach = tmuxAttach
        self.approveHostKey = approveHostKey
        terminalView = RetoTerminalView(frame: .zero)
        terminalView.apply(preferences)

        terminalView.onInput = { [weak self] bytes in
            self?.send(bytes)
        }
        terminalView.onResize = { [weak self] cols, rows, pixelWidth, pixelHeight in
            self?.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        terminalView.onTitleChange = { [weak self] title in
            self?.terminalTitle = title
        }

        connect()
    }

    var title: String {
        let remoteTitle = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remoteTitle.isEmpty { return remoteTitle }
        if let tmuxAttach { return "\(profile.displayName) · \(tmuxAttach.sessionName)" }
        if profile.usesTmux { return "\(profile.displayName) · \(profile.tmuxSession)" }
        return profile.displayName
    }

    /// The tmux session this tab stands for, used to avoid duplicate tabs.
    var tmuxIdentity: TmuxTabIdentity? {
        if let tmuxAttach {
            return TmuxTabIdentity(
                profileID: profile.id,
                sessionID: tmuxAttach.sessionID,
                sessionName: tmuxAttach.sessionName
            )
        }
        if profile.usesTmux {
            return TmuxTabIdentity(
                profileID: profile.id,
                sessionID: nil,
                sessionName: profile.normalized.tmuxSession
            )
        }
        return nil
    }

    var startupCommand: String? {
        if let tmuxAttach { return TmuxDiscovery.attachCommand(target: tmuxAttach.target) }
        return profile.tmuxStartupCommand
    }

    func connect() {
        wantsConnection = true
        connectionTask?.cancel()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let previousEngine = engine
        engine = Self.makeConnectionEngine(for: profile)
        state = .connecting
        terminalView.feed(text: "\r\n[reto] Connecting to \(profile.endpoint)…\r\n")

        let engine = engine
        let profile = profile
        let startupCommand = startupCommand
        let approveHostKey = approveHostKey
        connectionTask = Task { [weak self] in
            await previousEngine.disconnect()
            do {
                try await engine.run(
                    profile: profile,
                    startupCommand: startupCommand,
                    approveHostKey: approveHostKey,
                    onOutput: { [weak self] bytes in
                        await self?.receive(bytes)
                    },
                    onReady: { [weak self] in
                        await self?.markConnected()
                    }
                )
                guard !Task.isCancelled, self?.connectionAttemptID == attemptID else { return }
                self?.state = .disconnected
                self?.terminalView.feed(text: "\r\n[reto] SSH session closed.\r\n")
            } catch is CancellationError {
                guard self?.connectionAttemptID == attemptID else { return }
                self?.state = .disconnected
            } catch {
                guard !Task.isCancelled, self?.connectionAttemptID == attemptID else { return }
                let message = error.localizedDescription
                self?.state = .failed(message)
                self?.terminalView.feed(text: "\r\n[reto] Connection failed: \(message)\r\n")
            }
        }
    }

    func disconnect() {
        wantsConnection = false
        stopConnection(state: .disconnected)
    }

    func suspendForBackground() {
        guard state == .connecting || state == .connected else { return }
        wantsConnection = true
        terminalView.feed(text: "\r\n[reto] Paused while the app is in the background.\r\n")
        stopConnection(state: .suspended)
    }

    func resumeAfterBackground() {
        guard wantsConnection, state == .suspended else { return }
        terminalView.feed(text: "[reto] Reconnecting after foreground activation…\r\n")
        connect()
    }

    func reconnectIfNeeded() {
        guard wantsConnection, state == .disconnected else { return }
        connect()
    }

    func dismissKeyboard() {
        _ = terminalView.resignFirstResponder()
    }

    func apply(_ preferences: TerminalPreferences) {
        terminalView.apply(preferences)
    }

    /// Feeds a special key (Esc, Ctrl+C, arrows, …) into the remote shell,
    /// used by the pet quick actions.
    func sendKeystroke(_ keystroke: TerminalKeystroke) {
        send(keystroke.bytes)
    }

    private func stopConnection(state nextState: TerminalConnectionState) {
        connectionAttemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        sendTask?.cancel()
        sendTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        state = nextState
        let engine = engine
        Task { await engine.disconnect() }
    }

    private func send(_ bytes: [UInt8]) {
        guard state == .connected, !bytes.isEmpty else { return }
        pendingInput.append(contentsOf: bytes)
        guard sendTask == nil else { return }

        sendTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingInput.isEmpty {
                let batch = self.pendingInput
                self.pendingInput.removeAll(keepingCapacity: true)
                do {
                    try await self.engine.send(batch)
                } catch {
                    guard !Task.isCancelled else { break }
                    self.terminalView.feed(text: "\r\n[reto] Connection lost while sending input. Reconnect to continue.\r\n")
                    self.state = .disconnected
                    await self.engine.disconnect()
                    break
                }
            }
            self.sendTask = nil
        }
    }

    private func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        resizeTask?.cancel()
        let engine = engine
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await engine.resize(
                cols: cols,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    private func receive(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
    }

    private func markConnected() {
        state = .connected
        let terminal = terminalView.getTerminal()
        let scale = terminalView.window?.windowScene?.screen.scale ?? terminalView.traitCollection.displayScale
        resize(
            cols: terminal.cols,
            rows: terminal.rows,
            pixelWidth: Int(terminalView.bounds.width * scale),
            pixelHeight: Int(terminalView.bounds.height * scale)
        )
    }

    private static func makeConnectionEngine(for profile: SSHProfile) -> any SSHConnectionEngineProtocol {
        switch profile.authenticationKind {
        case .password:
            LibSSH2ConnectionEngine()
        case .privateKey:
            SSHConnectionEngine()
        }
    }
}

/// Read-only summary of a `BrowserWorkspace`, handed to `TerminalWorkspaceStore`
/// by the view layer so the SSH profile editor's workspace picker can show
/// names without this store depending on `WorkspaceBrowserStore` directly.
struct TerminalWorkspaceSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

@MainActor
@Observable
final class TerminalWorkspaceStore {
    static let launcherStorageKey = "reto-browser.terminal-launcher.v1"

    /// How often the app re-reads `@modot_*` pane options while tmux tabs are
    /// connected and the app is foregrounded.
    static let agentPollInterval: Duration = .seconds(30)

    var profiles: [SSHProfile]
    var terminalPreferences: TerminalPreferences
    var tabs: [TerminalSession] = []
    var selectedTabID: UUID?
    var launcherEnabled: Bool
    var presentedSurface: TerminalSurface?
    private(set) var phoneSheetMinimized = false
    var presentedSheet: TerminalSheetDestination?
    var pendingHostTrust: HostTrustRequest?
    var storageErrorMessage: String?
    var tmuxDiscovery: [UUID: TmuxDiscoveryState] = [:]

    /// The active `BrowserWorkspace.id`, mirrored one-way from
    /// `WorkspaceBrowserStore` by the view layer (the same pattern used for
    /// `WorkspaceBrowserStore.layoutIsCompact`) — this store never reaches
    /// back into the browser store. nil until the view layer has synced at
    /// least once, in which case profile visibility fails open (shows
    /// everything) rather than hiding servers behind an unknown workspace.
    var activeWorkspaceID: UUID?
    /// Workspace names for the SSH profile editor's "Workspace" picker.
    var availableWorkspaces: [TerminalWorkspaceSummary] = []
    /// Group names for the SSH profile editor's "Group" picker and the
    /// sidebar's group sections.
    var availableGroups: [ServiceGroup] = []

    /// Profiles visible from the active workspace, mirroring
    /// `WorkspaceBrowserStore.visibleBookmarks` exactly: nil `workspaceID`
    /// on the profile means shared, nil `activeWorkspaceID` here (not yet
    /// wired by the view layer) means "unknown, so show everything."
    var visibleProfiles: [SSHProfile] {
        guard let activeWorkspaceID else { return profiles }
        return profiles.filter { $0.isVisible(in: activeWorkspaceID) }
    }

    func setActiveWorkspace(_ workspaceID: UUID?) {
        activeWorkspaceID = workspaceID
    }

    /// Whether a live tab's profile is scoped to a workspace other than the
    /// active one. The tab itself is never closed for this — SSH connections
    /// stay alive across workspace switches — this only flags it in the UI.
    func tabBelongsToOtherWorkspace(_ tab: TerminalSession) -> Bool {
        guard let activeWorkspaceID, let tabWorkspaceID = tab.profile.workspaceID else { return false }
        return tabWorkspaceID != activeWorkspaceID
    }

    /// Receives deduplicated agent events (the pet listens here). Optional:
    /// nothing depends on it being set.
    @ObservationIgnored var agentEventHandler: ((TerminalAgentNotification) -> Void)?
    /// Injectable for tests so discovery never has to open a real connection.
    @ObservationIgnored var makeCommandRunner: (SSHProfile) -> any SSHOneShotCommandRunning = {
        SSHOneShotCommandRunnerFactory.makeRunner(for: $0)
    }

    @ObservationIgnored private let vault: SSHProfileVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var trustQueue: [HostTrustRequest] = []
    @ObservationIgnored private var trustContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var eventDeduplicators: [UUID: TmuxAgentEventDeduplicator] = [:]
    @ObservationIgnored private var agentPollTask: Task<Void, Never>?

    init(
        vault: SSHProfileVault = KeychainSSHProfileVault(),
        defaults: UserDefaults = .standard
    ) {
        self.vault = vault
        self.defaults = defaults
        presentedSurface = nil
        presentedSheet = nil
        pendingHostTrust = nil
        storageErrorMessage = nil
        launcherEnabled = defaults.bool(forKey: Self.launcherStorageKey)
        terminalPreferences = TerminalPreferences.load(from: defaults)

        do {
            profiles = try vault.loadProfiles()
        } catch {
            profiles = []
            storageErrorMessage = error.localizedDescription
        }
    }

    deinit {
        agentPollTask?.cancel()
    }

    var selectedTab: TerminalSession? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    func toggleLauncher() {
        launcherEnabled.toggle()
        defaults.set(launcherEnabled, forKey: Self.launcherStorageKey)
        if !launcherEnabled {
            closeSurface()
        }
    }

    func toggleSurface() {
        if presentedSurface == nil || phoneSheetMinimized {
            presentTerminal()
        } else {
            closeSurface()
        }
    }

    func presentTerminal() {
        presentedSurface = .terminal
        phoneSheetMinimized = false
    }

    func minimizeSurface() {
        guard presentedSurface != nil else { return }
        phoneSheetMinimized = true
    }

    func closeSurface() {
        phoneSheetMinimized = false
        presentedSurface = nil
    }

    func presentProfiles() {
        presentTerminal()
        presentedSheet = .profiles
    }

    func presentProfileEditor(_ profile: SSHProfile = SSHProfile()) {
        presentTerminal()
        presentedSheet = .profileEditor(profile)
    }

    func openTab(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        presentTerminal()
        appendTab(profile: profile, tmuxAttach: nil)
    }

    /// Opens a tab attached to a session found by tmux discovery. If a tab
    /// already shows that session (fixed-profile or discovered), it is
    /// selected instead of opening a duplicate.
    func openDiscoveredTmuxSession(profileID: UUID, session: TmuxSessionSummary) {
        presentTerminal()
        if let existing = tabs.first(where: {
            $0.tmuxIdentity?.represents(
                profileID: profileID,
                sessionID: session.sessionID,
                sessionName: session.name
            ) == true
        }) {
            selectedTabID = existing.id
            existing.reconnectIfNeeded()
            return
        }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        appendTab(profile: profile, tmuxAttach: TmuxAttachIntent(session: session))
    }

    private func appendTab(profile: SSHProfile, tmuxAttach: TmuxAttachIntent?) {
        let sessionID = UUID()
        let session = TerminalSession(
            id: sessionID,
            profile: profile,
            tmuxAttach: tmuxAttach,
            preferences: terminalPreferences
        ) { [weak self] fingerprint, expected in
            guard let self else { return false }
            return await self.requestHostTrust(
                sessionID: sessionID,
                profile: profile,
                fingerprint: fingerprint,
                expectedFingerprint: expected
            )
        }
        tabs.append(session)
        selectedTabID = session.id
        startAgentEventMonitorIfNeeded()
    }

    func updateTerminalPreferences(_ preferences: TerminalPreferences) {
        terminalPreferences = TerminalPreferences(
            font: preferences.font,
            fontSize: preferences.fontSize,
            theme: preferences.theme,
            hotkeyGroups: preferences.hotkeyGroups
        )
        terminalPreferences.save(to: defaults)
        tabs.forEach { $0.apply(terminalPreferences) }
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
    }

    /// Sends a special key to the focused terminal tab. Returns false when no
    /// connected terminal is available to receive it.
    @discardableResult
    func sendKeystroke(_ keystroke: TerminalKeystroke) -> Bool {
        guard let tab = selectedTab, tab.state == .connected else { return false }
        tab.sendKeystroke(keystroke)
        return true
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].disconnect()
        cancelHostTrustRequests(for: tabID)
        tabs.remove(at: index)

        if selectedTabID == tabID {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    @discardableResult
    func saveProfile(_ profile: SSHProfile) -> Bool {
        let profile = profile.normalized
        guard let validationMessage = profile.validationMessage else {
            let previous = profiles
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            guard persistProfiles() else {
                profiles = previous
                return false
            }
            return true
        }

        storageErrorMessage = validationMessage
        return false
    }

    func deleteProfile(_ profileID: UUID) {
        let previous = profiles
        profiles.removeAll(where: { $0.id == profileID })
        if !persistProfiles() {
            profiles = previous
        }
    }

    func assignProfile(_ profileID: UUID, toGroup groupID: UUID?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let previous = profiles
        profiles[index].groupID = groupID
        guard persistProfiles() else {
            profiles = previous
            return
        }
        syncLiveTabProfile(profileID) { $0.groupID = groupID }
    }

    func assignProfile(_ profileID: UUID, toWorkspace workspaceID: UUID?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let previous = profiles
        profiles[index].workspaceID = workspaceID
        guard persistProfiles() else {
            profiles = previous
            return
        }
        syncLiveTabProfile(profileID) { $0.workspaceID = workspaceID }
    }

    /// Clears `groupID` on member profiles when their group is deleted, the
    /// same way `WorkspaceBrowserStore.deleteGroup` already does for
    /// bookmarks and tabs. Called alongside that method by the view layer —
    /// this store has no reference to `WorkspaceBrowserStore` to call it
    /// automatically.
    func clearGroup(_ groupID: UUID) {
        let previous = profiles
        var changed = false
        for index in profiles.indices where profiles[index].groupID == groupID {
            profiles[index].groupID = nil
            changed = true
        }
        guard changed else { return }
        guard persistProfiles() else {
            profiles = previous
            return
        }
        for tab in tabs where tab.profile.groupID == groupID {
            tab.profile.groupID = nil
        }
    }

    /// D1.5 decision: deleting a workspace resets profiles scoped to it back
    /// to shared (nil) rather than deleting a server the user configured —
    /// the same "never destroy user-entered connection details" reasoning
    /// that already governs `ServiceBookmark`'s equivalent nil-means-shared
    /// default. Called alongside `WorkspaceBrowserStore.deleteWorkspace` by
    /// the view layer.
    func resetWorkspaceScopedProfiles(_ workspaceID: UUID) {
        let previous = profiles
        var changed = false
        for index in profiles.indices where profiles[index].workspaceID == workspaceID {
            profiles[index].workspaceID = nil
            changed = true
        }
        guard changed else { return }
        guard persistProfiles() else {
            profiles = previous
            return
        }
        for tab in tabs where tab.profile.workspaceID == workspaceID {
            tab.profile.workspaceID = nil
        }
    }

    private func syncLiveTabProfile(_ profileID: UUID, _ mutate: (inout SSHProfile) -> Void) {
        for tab in tabs where tab.profile.id == profileID {
            mutate(&tab.profile)
        }
    }

    func resetHostKey(for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let previous = profiles
        profiles[index].hostKeyFingerprint = nil
        if !persistProfiles() {
            profiles = previous
        }
    }

    func resolveHostTrust(_ request: HostTrustRequest, accept: Bool) {
        guard trustContinuations[request.id] != nil else { return }
        var accepted = accept

        if accept {
            accepted = persistFingerprint(request.presentedFingerprint, for: request.profileID)
        }

        trustContinuations.removeValue(forKey: request.id)?.resume(returning: accepted)
        trustQueue.removeAll(where: { $0.id == request.id })
        pendingHostTrust = trustQueue.first
    }

    func dismissStorageError() {
        storageErrorMessage = nil
    }

    private func requestHostTrust(
        sessionID: UUID,
        profile: SSHProfile,
        fingerprint: String,
        expectedFingerprint: String?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = HostTrustRequest(
                id: UUID(),
                sessionID: sessionID,
                profileID: profile.id,
                profileName: profile.displayName,
                host: profile.host,
                presentedFingerprint: fingerprint,
                expectedFingerprint: expectedFingerprint
            )
            trustContinuations[request.id] = continuation
            trustQueue.append(request)
            if pendingHostTrust == nil {
                pendingHostTrust = request
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // SSH stays suspended in the background; agent polling stops with it.
            stopAgentEventMonitor()
            for tab in tabs {
                tab.suspendForBackground()
                cancelHostTrustRequests(for: tab.id)
            }
        case .active:
            tabs.forEach { $0.resumeAfterBackground() }
            startAgentEventMonitorIfNeeded()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - tmux discovery

    func presentTmuxSessions() {
        presentTerminal()
        presentedSheet = .tmuxSessions
    }

    /// User-initiated discovery for one profile. May present the host-trust
    /// prompt; results land in `tmuxDiscovery`.
    func refreshTmuxSessions(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        var state = tmuxDiscovery[profileID] ?? TmuxDiscoveryState()
        guard !state.isLoading else { return }
        state.isLoading = true
        tmuxDiscovery[profileID] = state

        let result = await fetchTmuxState(profile: profile, interactive: true)

        var next = tmuxDiscovery[profileID] ?? TmuxDiscoveryState()
        next.isLoading = false
        next.result = result
        next.refreshedAt = Date()
        tmuxDiscovery[profileID] = next
        handleAgentMetadata(result, profile: profile)
    }

    private func fetchTmuxState(profile: SSHProfile, interactive: Bool) async -> TmuxQueryResult {
        let runner = makeCommandRunner(profile)
        let approval: SSHHostKeyApproval
        if interactive {
            let requestSessionID = UUID()
            approval = { [weak self] fingerprint, expected in
                guard let self else { return false }
                return await self.requestHostTrust(
                    sessionID: requestSessionID,
                    profile: profile,
                    fingerprint: fingerprint,
                    expectedFingerprint: expected
                )
            }
        } else {
            // Background polls never prompt: unknown or changed host keys
            // simply fail the poll.
            approval = { _, _ in false }
        }

        do {
            let result = try await runner.run(
                command: TmuxDiscovery.listPanesCommand,
                profile: profile,
                approveHostKey: approval
            )
            return TmuxDiscovery.classify(exitCode: result.exitCode, output: result.output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Forwards fresh `@modot_*` events to the pet (or whoever listens).
    /// Panes without metadata are the normal case and produce nothing.
    private func handleAgentMetadata(_ result: TmuxQueryResult, profile: SSHProfile) {
        guard case .sessions(let sessions) = result else { return }
        let panes = sessions.flatMap(\.panes)
        var deduplicator = eventDeduplicators[profile.id] ?? TmuxAgentEventDeduplicator()
        let events = deduplicator.events(from: panes)
        eventDeduplicators[profile.id] = deduplicator

        guard let handler = agentEventHandler else { return }
        for event in events {
            let tabID = tabs.first(where: {
                $0.tmuxIdentity?.represents(
                    profileID: profile.id,
                    sessionID: event.sessionID,
                    sessionName: event.sessionName
                ) == true
            })?.id
            handler(
                TerminalAgentNotification(
                    event: event,
                    profileID: profile.id,
                    profileName: profile.displayName,
                    tabID: tabID
                )
            )
        }
    }

    private func startAgentEventMonitorIfNeeded() {
        guard agentPollTask == nil else { return }
        agentPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.agentPollInterval)
                guard !Task.isCancelled else { return }
                await self?.pollTmuxAgentMetadata()
            }
        }
    }

    private func stopAgentEventMonitor() {
        agentPollTask?.cancel()
        agentPollTask = nil
    }

    private func pollTmuxAgentMetadata() async {
        guard agentEventHandler != nil else { return }
        // Only hosts that already have a connected tmux tab and a pinned host
        // key are polled; each poll is one short-lived exec connection.
        let profileIDs = Set(
            tabs.compactMap { tab -> UUID? in
                guard tab.state == .connected,
                      tab.tmuxIdentity != nil,
                      tab.profile.hostKeyFingerprint != nil else { return nil }
                return tab.profile.id
            }
        )
        for profileID in profileIDs {
            guard let profile = profiles.first(where: { $0.id == profileID }) else { continue }
            let result = await fetchTmuxState(profile: profile, interactive: false)
            if case .sessions = result {
                var state = tmuxDiscovery[profileID] ?? TmuxDiscoveryState()
                state.result = result
                state.refreshedAt = Date()
                tmuxDiscovery[profileID] = state
            }
            handleAgentMetadata(result, profile: profile)
        }
    }

    private func cancelHostTrustRequests(for sessionID: UUID) {
        let requests = trustQueue.filter { $0.sessionID == sessionID }
        for request in requests {
            trustContinuations.removeValue(forKey: request.id)?.resume(returning: false)
        }
        trustQueue.removeAll(where: { $0.sessionID == sessionID })
        if pendingHostTrust?.sessionID == sessionID {
            pendingHostTrust = trustQueue.first
        }
    }

    private func persistFingerprint(_ fingerprint: String, for profileID: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return false }
        let previous = profiles
        profiles[index].hostKeyFingerprint = fingerprint

        guard persistProfiles() else {
            profiles = previous
            return false
        }

        for tab in tabs where tab.profile.id == profileID {
            tab.profile.hostKeyFingerprint = fingerprint
        }
        return true
    }

    private func persistProfiles() -> Bool {
        do {
            try vault.saveProfiles(profiles)
            return true
        } catch {
            storageErrorMessage = error.localizedDescription
            return false
        }
    }
}
