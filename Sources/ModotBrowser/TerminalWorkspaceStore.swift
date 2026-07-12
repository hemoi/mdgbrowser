import Observation
import SwiftTerm
import SwiftUI
import UIKit

@MainActor
final class ModotTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
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
        font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        nativeBackgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.055, alpha: 1)
        nativeForegroundColor = UIColor(red: 0.90, green: 0.93, blue: 0.96, alpha: 1)
        optionAsMetaKey = false
        allowMouseReporting = true
        accessibilityIdentifier = "terminal.emulator"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    @ObservationIgnored let terminalView: ModotTerminalView
    @ObservationIgnored private var engine: any SSHConnectionEngineProtocol = SSHConnectionEngine()
    @ObservationIgnored private let approveHostKey: HostKeyApproval
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput: [UInt8] = []
    @ObservationIgnored private var connectionAttemptID = UUID()
    @ObservationIgnored private var wantsConnection = true

    init(id: UUID = UUID(), profile: SSHProfile, approveHostKey: @escaping HostKeyApproval) {
        self.id = id
        self.profile = profile
        self.approveHostKey = approveHostKey
        terminalView = ModotTerminalView(frame: .zero)

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
        if profile.usesTmux { return "\(profile.displayName) · \(profile.tmuxSession)" }
        return profile.displayName
    }

    func connect() {
        wantsConnection = true
        connectionTask?.cancel()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let previousEngine = engine
        engine = Self.makeConnectionEngine(for: profile)
        state = .connecting
        terminalView.feed(text: "\r\n[modot] Connecting to \(profile.endpoint)…\r\n")

        let engine = engine
        let profile = profile
        let approveHostKey = approveHostKey
        connectionTask = Task { [weak self] in
            await previousEngine.disconnect()
            do {
                try await engine.run(
                    profile: profile,
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
                self?.terminalView.feed(text: "\r\n[modot] SSH session closed.\r\n")
            } catch is CancellationError {
                guard self?.connectionAttemptID == attemptID else { return }
                self?.state = .disconnected
            } catch {
                guard !Task.isCancelled, self?.connectionAttemptID == attemptID else { return }
                let message = error.localizedDescription
                self?.state = .failed(message)
                self?.terminalView.feed(text: "\r\n[modot] Connection failed: \(message)\r\n")
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
        terminalView.feed(text: "\r\n[modot] Paused while the app is in the background.\r\n")
        stopConnection(state: .suspended)
    }

    func resumeAfterBackground() {
        guard wantsConnection, state == .suspended else { return }
        terminalView.feed(text: "[modot] Reconnecting after foreground activation…\r\n")
        connect()
    }

    func reconnectIfNeeded() {
        guard wantsConnection, state == .disconnected else { return }
        connect()
    }

    func dismissKeyboard() {
        _ = terminalView.resignFirstResponder()
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
                    self.terminalView.feed(text: "\r\n[modot] Connection lost while sending input. Reconnect to continue.\r\n")
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

@MainActor
@Observable
final class TerminalWorkspaceStore {
    static let launcherStorageKey = "modot-browser.terminal-launcher.v1"

    var profiles: [SSHProfile]
    var tabs: [TerminalSession] = []
    var selectedTabID: UUID?
    var launcherEnabled: Bool
    var presentedSurface: TerminalSurface?
    var presentedSheet: TerminalSheetDestination?
    var pendingHostTrust: HostTrustRequest?
    var storageErrorMessage: String?

    @ObservationIgnored private let vault: SSHProfileVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var trustQueue: [HostTrustRequest] = []
    @ObservationIgnored private var trustContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

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

        do {
            profiles = try vault.loadProfiles()
        } catch {
            profiles = []
            storageErrorMessage = error.localizedDescription
        }
    }

    var selectedTab: TerminalSession? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    func toggleLauncher() {
        launcherEnabled.toggle()
        defaults.set(launcherEnabled, forKey: Self.launcherStorageKey)
        if !launcherEnabled {
            presentedSurface = nil
        }
    }

    func toggleSurface() {
        presentedSurface = presentedSurface == nil ? .terminal : nil
    }

    func presentTerminal() {
        presentedSurface = .terminal
    }

    func presentProfiles() {
        presentedSurface = .terminal
        presentedSheet = .profiles
    }

    func presentProfileEditor(_ profile: SSHProfile = SSHProfile()) {
        presentedSurface = .terminal
        presentedSheet = .profileEditor(profile)
    }

    func openTab(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        presentedSurface = .terminal
        let sessionID = UUID()
        let session = TerminalSession(id: sessionID, profile: profile) { [weak self] fingerprint, expected in
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
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
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
            for tab in tabs {
                tab.suspendForBackground()
                cancelHostTrustRequests(for: tab.id)
            }
        case .active:
            tabs.forEach { $0.resumeAfterBackground() }
        case .inactive:
            break
        @unknown default:
            break
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
