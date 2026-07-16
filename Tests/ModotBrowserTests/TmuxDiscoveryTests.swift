import XCTest
@testable import ModotBrowser

final class TmuxDiscoveryTests: XCTestCase {
    private let separator = String(TmuxDiscovery.fieldSeparator)

    private func paneLine(
        sessionID: String = "$1",
        sessionName: String = "main",
        attached: String = "1",
        windowIndex: String = "0",
        windowActive: String = "1",
        paneID: String = "%4",
        paneIndex: String = "0",
        paneActive: String = "1",
        command: String = "zsh",
        path: String = "/home/modot",
        title: String = "modot@host",
        agent: String = "",
        event: String = "",
        eventAt: String = "",
        message: String = ""
    ) -> String {
        [
            sessionID, sessionName, attached, windowIndex, windowActive,
            paneID, paneIndex, paneActive, command, path, title,
            agent, event, eventAt, message,
        ].joined(separator: separator)
    }

    private func pane(
        sessionID: String = "$1",
        sessionName: String = "main",
        paneID: String = "%4",
        command: String = "zsh",
        title: String = "modot@host",
        agent: String? = nil,
        event: String? = nil,
        message: String? = nil,
        eventAt: String? = nil
    ) -> TmuxPane {
        TmuxPane(
            sessionID: sessionID,
            sessionName: sessionName,
            sessionAttached: true,
            windowIndex: 0,
            windowActive: true,
            paneID: paneID,
            paneIndex: 0,
            paneActive: true,
            currentCommand: command,
            currentPath: "/home/modot",
            title: title,
            metadata: TmuxModotMetadata(agent: agent, event: event, message: message, eventAt: eventAt)
        )
    }

    // MARK: - Format parsing

    func testParsesPanesWithAndWithoutModotMetadata() throws {
        let output = [
            paneLine(),
            paneLine(
                sessionID: "$2",
                sessionName: "agents",
                attached: "0",
                windowIndex: "3",
                windowActive: "0",
                paneID: "%9",
                paneIndex: "1",
                paneActive: "0",
                command: "node",
                path: "/srv/repo",
                title: "✳ Claude Code",
                agent: "claude",
                event: "waiting",
                eventAt: "1752600000",
                message: "Needs plan approval"
            ),
        ].joined(separator: "\n")

        let panes = TmuxDiscovery.parseListPanesOutput(output)

        XCTAssertEqual(panes.count, 2)
        let plain = try XCTUnwrap(panes.first)
        XCTAssertEqual(plain.sessionID, "$1")
        XCTAssertEqual(plain.sessionName, "main")
        XCTAssertTrue(plain.sessionAttached)
        XCTAssertTrue(plain.metadata.isEmpty)

        let agent = try XCTUnwrap(panes.last)
        XCTAssertEqual(agent.paneID, "%9")
        XCTAssertEqual(agent.windowIndex, 3)
        XCTAssertFalse(agent.sessionAttached)
        XCTAssertEqual(agent.metadata.agent, "claude")
        XCTAssertEqual(agent.metadata.event, "waiting")
        XCTAssertEqual(agent.metadata.eventAt, "1752600000")
        XCTAssertEqual(agent.metadata.message, "Needs plan approval")
    }

    func testParsingSkipsMalformedLinesAndKeepsValidOnes() {
        let output = [
            "no server running on /private/tmp/tmux-501/default",
            paneLine(sessionID: "not-a-session-id"),
            paneLine(paneID: "not-a-pane-id"),
            paneLine(windowIndex: "three"),
            paneLine(paneID: "%7"),
        ].joined(separator: "\n")

        let panes = TmuxDiscovery.parseListPanesOutput(output)

        XCTAssertEqual(panes.map(\.paneID), ["%7"])
    }

    func testSeparatorInsideMessageStaysInMessage() throws {
        let messageWithSeparator = "part one\(separator)part two"
        let output = paneLine(event: "done", message: messageWithSeparator)

        let panes = TmuxDiscovery.parseListPanesOutput(output)

        XCTAssertEqual(try XCTUnwrap(panes.first).metadata.message, messageWithSeparator)
    }

    func testSessionsGroupPanesInServerOrder() {
        let panes = [
            pane(sessionID: "$3", sessionName: "beta", paneID: "%1"),
            pane(sessionID: "$1", sessionName: "alpha", paneID: "%2"),
            pane(sessionID: "$3", sessionName: "beta", paneID: "%3"),
        ]

        let sessions = TmuxDiscovery.sessions(from: panes)

        XCTAssertEqual(sessions.map(\.sessionID), ["$3", "$1"])
        XCTAssertEqual(sessions.first?.panes.count, 2)
        XCTAssertEqual(sessions.first?.name, "beta")
    }

    // MARK: - Result classification

    func testClassifyTreatsMissingTmuxAndStoppedServerAsNormalStates() {
        XCTAssertEqual(
            TmuxDiscovery.classify(exitCode: 127, output: "sh: tmux: command not found"),
            .tmuxNotInstalled
        )
        XCTAssertEqual(
            TmuxDiscovery.classify(exitCode: 1, output: "zsh:1: command not found: tmux"),
            .tmuxNotInstalled
        )
        XCTAssertEqual(
            TmuxDiscovery.classify(exitCode: 1, output: "no server running on /private/tmp/tmux-501/default"),
            .noServer
        )
        XCTAssertEqual(
            TmuxDiscovery.classify(exitCode: 1, output: "failed to connect to server"),
            .noServer
        )
    }

    func testClassifySuccessParsesSessionsAndFailureKeepsDiagnostics() {
        let success = TmuxDiscovery.classify(exitCode: 0, output: paneLine())
        guard case .sessions(let sessions) = success else {
            return XCTFail("Expected sessions, got \(success)")
        }
        XCTAssertEqual(sessions.map(\.name), ["main"])

        let failure = TmuxDiscovery.classify(exitCode: 255, output: "kex_exchange failed")
        XCTAssertEqual(failure, .failed("kex_exchange failed"))
    }

    // MARK: - Agent classification

    func testHeuristicDetectionFromCommandAndTitleIsMarkedUncertain() {
        XCTAssertEqual(
            TmuxDiscovery.detectAgent(command: "claude", title: "", declaredAgent: nil),
            .heuristic(.claude)
        )
        XCTAssertEqual(
            TmuxDiscovery.detectAgent(command: "codex", title: "", declaredAgent: nil),
            .heuristic(.codex)
        )
        XCTAssertEqual(
            TmuxDiscovery.detectAgent(command: "node", title: "✳ Claude Code — repo", declaredAgent: nil),
            .heuristic(.claude)
        )
        XCTAssertFalse(TmuxAgentDetection.heuristic(.claude).isCertain)
    }

    func testDeclaredMetadataWinsAndIsCertain() {
        let detection = TmuxDiscovery.detectAgent(
            command: "node",
            title: "codex running",
            declaredAgent: " Claude \n"
        )

        XCTAssertEqual(detection, .declared(.claude))
        XCTAssertTrue(detection.isCertain)
    }

    func testUnrelatedPanesAreNotClassified() {
        XCTAssertEqual(
            TmuxDiscovery.detectAgent(command: "vim", title: "server.py", declaredAgent: nil),
            .none
        )
        XCTAssertEqual(
            TmuxDiscovery.detectAgent(command: "zsh", title: "", declaredAgent: "unknown-agent"),
            .none
        )
    }

    // MARK: - Safe target construction

    func testAttachTargetAcceptsOnlyTmuxSessionIDs() {
        XCTAssertEqual(TmuxAttachTarget(sessionID: "$0")?.argument, "'$0'")
        XCTAssertEqual(TmuxAttachTarget(sessionID: "$42")?.argument, "'$42'")
        XCTAssertNil(TmuxAttachTarget(sessionID: "main"))
        XCTAssertNil(TmuxAttachTarget(sessionID: "$"))
        XCTAssertNil(TmuxAttachTarget(sessionID: "$4x"))
        XCTAssertNil(TmuxAttachTarget(sessionID: "%3"))
        XCTAssertNil(TmuxAttachTarget(sessionID: "$4; reboot"))
    }

    func testSessionNameQuotingNeutralizesShellMetacharacters() {
        let target = TmuxAttachTarget(quotingSessionName: "pwn'; reboot #")

        XCTAssertEqual(target.argument, "'pwn'\\''; reboot #'")
        XCTAssertEqual(
            TmuxDiscovery.attachCommand(target: target),
            "tmux -u attach-session -t 'pwn'\\''; reboot #'\r"
        )
    }

    func testAttachIntentPrefersStableSessionID() {
        let session = TmuxSessionSummary(
            sessionID: "$7",
            name: "deploy; rm -rf /",
            isAttached: false,
            panes: []
        )

        let intent = TmuxAttachIntent(session: session)

        XCTAssertEqual(intent.target.argument, "'$7'")
        XCTAssertEqual(
            TmuxDiscovery.attachCommand(target: intent.target),
            "tmux -u attach-session -t '$7'\r"
        )
    }

    func testListPanesCommandIsAConstantWithQuotedFormat() {
        XCTAssertTrue(TmuxDiscovery.listPanesCommand.hasPrefix("tmux list-panes -a -F '"))
        XCTAssertTrue(TmuxDiscovery.listPanesCommand.contains("#{session_id}"))
        XCTAssertTrue(TmuxDiscovery.listPanesCommand.contains("#{@modot_event}"))
    }

    // MARK: - Event deduplication

    func testFreshEventEmitsOnceAndReemitsWhenStampChanges() {
        var deduplicator = TmuxAgentEventDeduplicator(stalenessWindow: 600)
        let now = Date()
        let fresh = String(Int(now.timeIntervalSince1970) - 30)
        let panes = [pane(event: "waiting", message: "Needs input", eventAt: fresh)]

        XCTAssertEqual(deduplicator.events(from: panes, now: now).count, 1)
        XCTAssertEqual(deduplicator.events(from: panes, now: now).count, 0)

        let later = String(Int(now.timeIntervalSince1970) + 60)
        let updated = [pane(event: "done", message: "Finished", eventAt: later)]
        let events = deduplicator.events(from: updated, now: now.addingTimeInterval(90))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "done")
        XCTAssertEqual(events.first?.message, "Finished")
    }

    func testStaleOrUndatedEventsAreNotReplayedOnFirstObservation() {
        var deduplicator = TmuxAgentEventDeduplicator(stalenessWindow: 600)
        let now = Date()
        let stale = String(Int(now.timeIntervalSince1970) - 4_000)

        XCTAssertTrue(deduplicator.events(from: [pane(event: "done", eventAt: stale)], now: now).isEmpty)
        XCTAssertTrue(deduplicator.events(from: [pane(paneID: "%8", event: "done")], now: now).isEmpty)

        // A change observed while running is a real event even without a date.
        let changed = deduplicator.events(
            from: [pane(paneID: "%8", event: "waiting", message: "Look at me")],
            now: now
        )
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.event, "waiting")
    }

    func testPanesWithoutEventMetadataEmitNothing() {
        var deduplicator = TmuxAgentEventDeduplicator()

        XCTAssertTrue(deduplicator.events(from: [pane(), pane(paneID: "%5", agent: "claude")]).isEmpty)
    }

    // MARK: - Tab identity matching

    func testTabIdentityMatchesBySessionIDThenName() {
        let profileID = UUID()
        let discovered = TmuxTabIdentity(profileID: profileID, sessionID: "$3", sessionName: "renamed")
        let fixed = TmuxTabIdentity(profileID: profileID, sessionID: nil, sessionName: "main")

        XCTAssertTrue(discovered.represents(profileID: profileID, sessionID: "$3", sessionName: "other"))
        XCTAssertFalse(discovered.represents(profileID: profileID, sessionID: "$4", sessionName: "renamed"))
        XCTAssertTrue(fixed.represents(profileID: profileID, sessionID: "$9", sessionName: "main"))
        XCTAssertFalse(fixed.represents(profileID: UUID(), sessionID: "$9", sessionName: "main"))
    }

    func testAgentNotificationTextIsHonestAboutUncertainty() {
        let event = TmuxAgentEvent(
            paneID: "%1",
            sessionID: "$1",
            sessionName: "main",
            detection: .heuristic(.claude),
            event: "waiting",
            message: nil,
            eventAt: nil
        )
        let heuristic = TerminalAgentNotification(
            event: event,
            profileID: UUID(),
            profileName: "Ops",
            tabID: nil
        )
        XCTAssertEqual(heuristic.petMessageText, "Claude? · main: waiting")

        let declared = TerminalAgentNotification(
            event: TmuxAgentEvent(
                paneID: "%1",
                sessionID: "$1",
                sessionName: "main",
                detection: .declared(.codex),
                event: "done",
                message: "Task finished",
                eventAt: nil
            ),
            profileID: UUID(),
            profileName: "Ops",
            tabID: nil
        )
        XCTAssertEqual(declared.petMessageText, "Codex · main: Task finished")
    }
}
