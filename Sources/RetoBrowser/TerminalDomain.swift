import Foundation

enum SSHAuthenticationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        }
    }
}

enum TerminalEmulation: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case xterm256Color
    case xterm
    case screen256Color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .xterm256Color: "xterm-256color"
        case .xterm: "xterm"
        case .screen256Color: "screen-256color"
        }
    }

    func resolvedTerm(usesTmux _: Bool) -> String {
        switch self {
        case .automatic:
            "xterm-256color"
        case .xterm256Color:
            "xterm-256color"
        case .xterm:
            "xterm"
        case .screen256Color:
            "screen-256color"
        }
    }
}

struct SSHProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let allowedTmuxSessionCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-."))

    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var authenticationKind: SSHAuthenticationKind
    var privateKey: String
    var privateKeyPassphrase: String
    var terminalEmulation: TerminalEmulation
    var usesTmux: Bool
    var tmuxSession: String
    var hostKeyFingerprint: String?
    /// The `ServiceGroup` this profile belongs to, so a group can contain
    /// bookmarks and SSH targets side by side. Mirrors `ServiceBookmark.groupID`.
    var groupID: UUID?
    /// nil means the profile is available in every workspace. Mirrors
    /// `ServiceBookmark.workspaceID` and `isVisible(in:)` exactly, so
    /// existing (pre-D1) saved profiles keep working everywhere after
    /// upgrading.
    var workspaceID: UUID?

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        password: String = "",
        authenticationKind: SSHAuthenticationKind = .password,
        privateKey: String = "",
        privateKeyPassphrase: String = "",
        terminalEmulation: TerminalEmulation = .automatic,
        usesTmux: Bool = false,
        tmuxSession: String = "main",
        hostKeyFingerprint: String? = nil,
        groupID: UUID? = nil,
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authenticationKind = authenticationKind
        self.privateKey = privateKey
        self.privateKeyPassphrase = privateKeyPassphrase
        self.terminalEmulation = terminalEmulation
        self.usesTmux = usesTmux
        self.tmuxSession = tmuxSession
        self.hostKeyFingerprint = hostKeyFingerprint
        self.groupID = groupID
        self.workspaceID = workspaceID
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? host : trimmedName
    }

    /// Same semantics as `ServiceBookmark.isVisible(in:)`: nil `workspaceID`
    /// is shared across every workspace, otherwise it must match exactly.
    func isVisible(in workspaceID: UUID) -> Bool {
        self.workspaceID == nil || self.workspaceID == workspaceID
    }

    var endpoint: String {
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let authority = username.isEmpty ? displayHost : "\(username)@\(displayHost)"
        return port == 22 ? authority : "\(authority):\(port)"
    }

    var resolvedTerminalType: String {
        terminalEmulation.resolvedTerm(usesTmux: usesTmux)
    }

    var normalized: SSHProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.privateKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tmuxSession = tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hostKeyFingerprint = hostKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.hostKeyFingerprint?.isEmpty == true {
            copy.hostKeyFingerprint = nil
        }
        return copy
    }

    var validationMessage: String? {
        let profile = normalized
        if profile.host.isEmpty { return "Host is required." }
        if profile.username.isEmpty { return "Username is required." }
        switch profile.authenticationKind {
        case .password:
            if profile.password.isEmpty { return "Password is required." }
        case .privateKey:
            if profile.privateKey.isEmpty { return "An OpenSSH private key is required." }
            if !profile.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
                return "The private key must use OpenSSH private-key format."
            }
        }
        if !(1...65_535).contains(profile.port) { return "Port must be between 1 and 65535." }

        if profile.usesTmux {
            if profile.tmuxSession.isEmpty { return "tmux session name is required." }
            if profile.tmuxSession.unicodeScalars.contains(where: {
                !Self.allowedTmuxSessionCharacters.contains($0)
            }) {
                return "tmux session may contain letters, numbers, dot, dash, and underscore only."
            }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, authenticationKind
        case privateKey, privateKeyPassphrase, terminalEmulation, usesTmux, tmuxSession, hostKeyFingerprint
        case groupID, workspaceID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        authenticationKind = try values.decodeIfPresent(SSHAuthenticationKind.self, forKey: .authenticationKind) ?? .password
        privateKey = try values.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        privateKeyPassphrase = try values.decodeIfPresent(String.self, forKey: .privateKeyPassphrase) ?? ""
        terminalEmulation = try values.decodeIfPresent(TerminalEmulation.self, forKey: .terminalEmulation) ?? .automatic
        usesTmux = try values.decodeIfPresent(Bool.self, forKey: .usesTmux) ?? false
        tmuxSession = try values.decodeIfPresent(String.self, forKey: .tmuxSession) ?? "main"
        hostKeyFingerprint = try values.decodeIfPresent(String.self, forKey: .hostKeyFingerprint)
        // Both new fields decode to nil when absent from a pre-D1 stored
        // profile, which keeps that profile visible in every workspace and
        // out of any group — the required migration guarantee.
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        workspaceID = try values.decodeIfPresent(UUID.self, forKey: .workspaceID)
    }

    var tmuxStartupCommand: String? {
        let profile = normalized
        guard profile.usesTmux, profile.validationMessage == nil else { return nil }
        return "tmux -u new-session -A -s \(profile.tmuxSession)\r"
    }
}

enum TerminalConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case suspended
    case disconnected
    case failed(String)

    var label: String {
        switch self {
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .suspended:
            "Paused in background"
        case .disconnected:
            "Disconnected"
        case .failed:
            "Connection failed"
        }
    }
}

enum TerminalSurface: String, Identifiable {
    case terminal

    var id: String { rawValue }
}

enum TerminalSheetDestination: Identifiable, Equatable {
    case profiles
    case profileEditor(SSHProfile)
    case tmuxSessions
    case settings

    var id: String {
        switch self {
        case .profiles:
            "profiles"
        case .profileEditor(let profile):
            "profile-editor-\(profile.id.uuidString)"
        case .tmuxSessions:
            "tmux-sessions"
        case .settings:
            "settings"
        }
    }
}

struct HostTrustRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let profileID: UUID
    let profileName: String
    let host: String
    let presentedFingerprint: String
    let expectedFingerprint: String?

    var hostKeyChanged: Bool {
        guard let expectedFingerprint else { return false }
        return expectedFingerprint != presentedFingerprint
    }
}

enum TerminalWireEncoding {
    static func bytes(for text: String) -> [UInt8] {
        Array(text.utf8)
    }
}

extension SSHProfile {
    static func draft(fromSSHAddress input: String) -> SSHProfile? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "ssh",
              let host = components.host,
              !host.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let port = components.port ?? 22
        guard (1...65_535).contains(port) else { return nil }

        return SSHProfile(
            host: host,
            port: port,
            username: components.user?.removingPercentEncoding ?? ""
        )
    }
}
