import Foundation

// MARK: - Agent detection

enum TmuxAgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// How a pane was identified as running a coding agent. `.declared` comes from
/// the opt-in `@modot_agent` pane option set by a user-installed hook and is
/// trusted; `.heuristic` is a guess from `pane_current_command`/`pane_title`
/// and the UI must present it as uncertain.
enum TmuxAgentDetection: Equatable, Sendable {
    case none
    case heuristic(TmuxAgentKind)
    case declared(TmuxAgentKind)

    var kind: TmuxAgentKind? {
        switch self {
        case .none: nil
        case .heuristic(let kind), .declared(let kind): kind
        }
    }

    var isCertain: Bool {
        if case .declared = self { return true }
        return false
    }
}

// MARK: - Discovered panes and sessions

/// Optional `@modot_*` pane options written by an inline Claude/Codex hook.
/// The app never installs those hooks; every field being absent is the normal
/// state for a pane, not an error.
struct TmuxModotMetadata: Equatable, Sendable {
    var agent: String?
    var event: String?
    var message: String?
    var eventAt: String?

    var isEmpty: Bool {
        agent == nil && event == nil && message == nil && eventAt == nil
    }
}

struct TmuxPane: Equatable, Identifiable, Sendable {
    /// tmux server-assigned session ID, e.g. "$3". Stable for the server's lifetime.
    let sessionID: String
    let sessionName: String
    let sessionAttached: Bool
    let windowIndex: Int
    let windowActive: Bool
    /// tmux server-assigned pane ID, e.g. "%12". Unique for the server's lifetime.
    let paneID: String
    let paneIndex: Int
    let paneActive: Bool
    let currentCommand: String
    let currentPath: String
    let title: String
    let metadata: TmuxModotMetadata

    var id: String { paneID }

    var agentDetection: TmuxAgentDetection {
        TmuxDiscovery.detectAgent(
            command: currentCommand,
            title: title,
            declaredAgent: metadata.agent
        )
    }
}

struct TmuxSessionSummary: Equatable, Identifiable, Sendable {
    let sessionID: String
    let name: String
    let isAttached: Bool
    let panes: [TmuxPane]

    var id: String { sessionID }

    var windowCount: Int {
        Set(panes.map(\.windowIndex)).count
    }

    var agentPanes: [TmuxPane] {
        panes.filter { $0.agentDetection != .none }
    }
}

/// Outcome of querying a host for tmux state. Only `.failed` is an error;
/// a missing tmux binary or a stopped server are ordinary answers.
enum TmuxQueryResult: Equatable, Sendable {
    case sessions([TmuxSessionSummary])
    case tmuxNotInstalled
    case noServer
    case failed(String)
}

// MARK: - Safe shell construction

enum ShellQuoting {
    /// POSIX single-quoting: safe for any byte sequence except that embedded
    /// single quotes are closed, escaped, and reopened.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A tmux `-t` target that is guaranteed safe to embed in a shell command.
/// Either a validated tmux-generated session ID ("$N") or a strictly
/// shell-quoted session name — never raw user/remote text.
struct TmuxAttachTarget: Equatable, Sendable {
    /// The already-quoted shell argument, e.g. `'$3'` or `'work'\''ing'`.
    let argument: String

    init?(sessionID: String) {
        guard sessionID.hasPrefix("$"),
              sessionID.count > 1,
              sessionID.dropFirst().allSatisfy(\.isNumber) else {
            return nil
        }
        argument = ShellQuoting.singleQuoted(sessionID)
    }

    init(quotingSessionName name: String) {
        argument = ShellQuoting.singleQuoted(name)
    }
}

// MARK: - tmux commands and parsing

enum TmuxDiscovery {
    /// Field separator for `list-panes -F` output. The ASCII unit separator
    /// never appears in commands or paths in practice and keeps parsing
    /// unambiguous without shell-side escaping.
    static let fieldSeparator: Character = "\u{1F}"

    /// `@modot_message` is free text, so it is deliberately the last field;
    /// any separator characters inside it are re-joined during parsing.
    private static let formatFields = [
        "#{session_id}",
        "#{session_name}",
        "#{session_attached}",
        "#{window_index}",
        "#{window_active}",
        "#{pane_id}",
        "#{pane_index}",
        "#{pane_active}",
        "#{pane_current_command}",
        "#{pane_current_path}",
        "#{pane_title}",
        "#{@modot_agent}",
        "#{@modot_event}",
        "#{@modot_event_at}",
        "#{@modot_message}",
    ]

    static var listPanesFormat: String {
        formatFields.joined(separator: String(fieldSeparator))
    }

    /// The complete remote command. It is a constant — no discovered or
    /// user-entered value is ever interpolated into it.
    static var listPanesCommand: String {
        "tmux list-panes -a -F \(ShellQuoting.singleQuoted(listPanesFormat)) 2>&1"
    }

    /// Startup command typed into a fresh interactive shell to attach a
    /// discovered session. The target is pre-quoted by `TmuxAttachTarget`.
    static func attachCommand(target: TmuxAttachTarget) -> String {
        "tmux -u attach-session -t \(target.argument)\r"
    }

    static func parseListPanesOutput(_ output: String) -> [TmuxPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parsePaneLine(String(line))
        }
    }

    private static func parsePaneLine(_ line: String) -> TmuxPane? {
        var fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= formatFields.count else { return nil }
        if fields.count > formatFields.count {
            // Separator bytes inside the free-text @modot_message field.
            let message = fields[(formatFields.count - 1)...].joined(separator: String(fieldSeparator))
            fields = Array(fields[..<(formatFields.count - 1)]) + [message]
        }

        guard let windowIndex = Int(fields[3]),
              let paneIndex = Int(fields[6]),
              fields[0].hasPrefix("$"),
              fields[5].hasPrefix("%") else {
            return nil
        }

        func optional(_ value: String) -> String? {
            value.isEmpty ? nil : value
        }

        return TmuxPane(
            sessionID: fields[0],
            sessionName: fields[1],
            sessionAttached: (Int(fields[2]) ?? 0) > 0,
            windowIndex: windowIndex,
            windowActive: fields[4] == "1",
            paneID: fields[5],
            paneIndex: paneIndex,
            paneActive: fields[7] == "1",
            currentCommand: fields[8],
            currentPath: fields[9],
            title: fields[10],
            metadata: TmuxModotMetadata(
                agent: optional(fields[11]),
                event: optional(fields[12]),
                message: optional(fields[14]),
                eventAt: optional(fields[13])
            )
        )
    }

    static func sessions(from panes: [TmuxPane]) -> [TmuxSessionSummary] {
        var order: [String] = []
        var grouped: [String: [TmuxPane]] = [:]
        for pane in panes {
            if grouped[pane.sessionID] == nil { order.append(pane.sessionID) }
            grouped[pane.sessionID, default: []].append(pane)
        }
        return order.compactMap { sessionID in
            guard let panes = grouped[sessionID], let first = panes.first else { return nil }
            return TmuxSessionSummary(
                sessionID: sessionID,
                name: first.sessionName,
                isAttached: first.sessionAttached,
                panes: panes
            )
        }
    }

    /// Maps a one-shot `list-panes` run to a user-readable state. tmux being
    /// absent (127) or having no server are normal answers, not failures.
    static func classify(exitCode: Int32?, output: String) -> TmuxQueryResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case .some(0):
            return .sessions(sessions(from: parseListPanesOutput(output)))
        case .some(127):
            return .tmuxNotInstalled
        default:
            let lowered = trimmed.lowercased()
            if lowered.contains("command not found") || lowered.contains("not found") && lowered.contains("tmux") {
                return .tmuxNotInstalled
            }
            if lowered.contains("no server running") || lowered.contains("failed to connect to server") {
                return .noServer
            }
            if lowered.contains("no current client") || lowered.contains("no sessions") {
                return .noServer
            }
            let detail = trimmed.isEmpty
                ? "tmux query failed (exit \(exitCode.map(String.init) ?? "unknown"))."
                : trimmed
            return .failed(String(detail.prefix(300)))
        }
    }

    static func detectAgent(command: String, title: String, declaredAgent: String?) -> TmuxAgentDetection {
        if let declared = declaredAgent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let kind = TmuxAgentKind(rawValue: declared) {
            return .declared(kind)
        }

        let command = command.lowercased()
        if command == "claude" || command.hasPrefix("claude-") { return .heuristic(.claude) }
        if command == "codex" || command.hasPrefix("codex-") { return .heuristic(.codex) }

        // Node-based CLIs usually report "node" as the command; the pane
        // title is the only remaining hint and is even less reliable.
        let title = title.lowercased()
        if title.contains("claude") { return .heuristic(.claude) }
        if title.contains("codex") { return .heuristic(.codex) }
        return .none
    }
}

// MARK: - Agent events

/// One agent-originated event surfaced through `@modot_*` pane options.
struct TmuxAgentEvent: Equatable, Sendable {
    let paneID: String
    let sessionID: String
    let sessionName: String
    let detection: TmuxAgentDetection
    let event: String
    let message: String?
    let eventAt: String?
}

/// Emits each pane event at most once, keyed by `@modot_event_at` (falling
/// back to a fingerprint of event+message). Panes seen for the first time
/// only emit when the event is recent, so relaunching the app does not replay
/// stale notifications.
struct TmuxAgentEventDeduplicator {
    var stalenessWindow: TimeInterval

    private var lastStamp: [String: String] = [:]

    init(stalenessWindow: TimeInterval = 600) {
        self.stalenessWindow = stalenessWindow
    }

    mutating func events(from panes: [TmuxPane], now: Date = Date()) -> [TmuxAgentEvent] {
        var emitted: [TmuxAgentEvent] = []
        for pane in panes {
            guard let event = pane.metadata.event else { continue }
            let stamp = pane.metadata.eventAt ?? "\(event)|\(pane.metadata.message ?? "")"
            let previous = lastStamp[pane.paneID]
            lastStamp[pane.paneID] = stamp
            guard previous != stamp else { continue }

            if previous == nil, !isRecent(eventAt: pane.metadata.eventAt, now: now) {
                // First observation of this pane: without a fresh timestamp
                // there is no way to tell a new event from a stale one.
                continue
            }

            emitted.append(
                TmuxAgentEvent(
                    paneID: pane.paneID,
                    sessionID: pane.sessionID,
                    sessionName: pane.sessionName,
                    detection: pane.agentDetection,
                    event: event,
                    message: pane.metadata.message,
                    eventAt: pane.metadata.eventAt
                )
            )
        }
        prune(activePaneIDs: Set(panes.map(\.paneID)))
        return emitted
    }

    private func isRecent(eventAt: String?, now: Date) -> Bool {
        guard let eventAt, let epoch = TimeInterval(eventAt) else { return false }
        let age = now.timeIntervalSince1970 - epoch
        return age >= 0 && age <= stalenessWindow
    }

    private mutating func prune(activePaneIDs: Set<String>) {
        lastStamp = lastStamp.filter { activePaneIDs.contains($0.key) }
    }
}

// MARK: - Attaching discovered sessions

/// Everything a terminal tab needs to attach a discovered session instead of
/// the profile's fixed tmux session.
struct TmuxAttachIntent: Equatable, Sendable {
    let sessionID: String
    let sessionName: String
    let target: TmuxAttachTarget

    init(session: TmuxSessionSummary) {
        sessionID = session.sessionID
        sessionName = session.name
        // Session IDs always match "$N"; the quoted-name path is a safety net
        // that still cannot leak shell metacharacters.
        target = TmuxAttachTarget(sessionID: session.sessionID)
            ?? TmuxAttachTarget(quotingSessionName: session.name)
    }
}

/// Per-profile discovery status shown by the session browser.
struct TmuxDiscoveryState: Equatable, Sendable {
    var isLoading = false
    var result: TmuxQueryResult?
    var refreshedAt: Date?
}

/// A deduplicated agent event, resolved against the open terminal tabs.
struct TerminalAgentNotification: Sendable {
    let event: TmuxAgentEvent
    let profileID: UUID
    let profileName: String
    /// The open tab showing the session the event came from, when there is one.
    let tabID: UUID?

    /// Bubble text. Heuristically detected agents keep a trailing "?" so the
    /// pet never overstates what it knows.
    var petMessageText: String {
        let agentLabel = (event.detection.kind?.label ?? "Agent")
            + (event.detection.isCertain ? "" : "?")
        let body = event.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = body.isEmpty ? event.event : body
        return "\(agentLabel) · \(event.sessionName): \(detail)"
    }
}

// MARK: - Matching discovered sessions to open tabs

/// The tmux identity a terminal tab represents, used to avoid opening a
/// second tab for a session that is already on screen.
struct TmuxTabIdentity: Equatable, Sendable {
    let profileID: UUID
    /// Server-assigned ID ("$3") when the tab came from discovery.
    let sessionID: String?
    /// Session name for both discovered and fixed-profile tmux tabs.
    let sessionName: String?

    func represents(profileID: UUID, sessionID: String, sessionName: String) -> Bool {
        guard self.profileID == profileID else { return false }
        if let ownID = self.sessionID { return ownID == sessionID }
        if let ownName = self.sessionName { return ownName == sessionName }
        return false
    }
}
