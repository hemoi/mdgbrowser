import SwiftUI

/// Browses tmux sessions on a saved SSH host over a one-shot exec command —
/// nothing is installed remotely and the visible terminal is never touched.
struct TmuxSessionBrowserSheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var chosenProfileID: UUID?

    let store: TerminalWorkspaceStore

    private var selectedProfile: SSHProfile? {
        if let chosenProfileID,
           let profile = store.profiles.first(where: { $0.id == chosenProfileID }) {
            return profile
        }
        if let activeProfileID = store.selectedTab?.profile.id,
           let profile = store.profiles.first(where: { $0.id == activeProfileID }) {
            return profile
        }
        return store.profiles.first
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Group {
                if let profile = selectedProfile {
                    profileContent(profile)
                } else {
                    ContentUnavailableView {
                        Label("No SSH Profiles", systemImage: "server.rack")
                    } description: {
                        Text("tmux discovery reuses your saved SSH profiles. Add one first.")
                    } actions: {
                        Button("Add Profile") {
                            store.presentedSheet = .profileEditor(SSHProfile())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("tmux Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let profile = selectedProfile {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            refresh(profile)
                        }
                        .disabled(store.tmuxDiscovery[profile.id]?.isLoading == true)
                        .accessibilityIdentifier("tmux.browser.refresh")
                    }
                }
            }
        }
        // The host-trust prompt can fire mid-refresh while this sheet covers
        // the terminal panel, so it needs its own presentation slot here.
        .alert(item: $store.pendingHostTrust) { request in
            TerminalHostTrustAlert.alert(for: request, store: store)
        }
        .task(id: selectedProfile?.id) {
            guard let profile = selectedProfile,
                  store.tmuxDiscovery[profile.id]?.result == nil else { return }
            await store.refreshTmuxSessions(profileID: profile.id)
        }
    }

    private func refresh(_ profile: SSHProfile) {
        Task { await store.refreshTmuxSessions(profileID: profile.id) }
    }

    private func open(_ session: TmuxSessionSummary, profile: SSHProfile) {
        store.openDiscoveredTmuxSession(profileID: profile.id, session: session)
        dismiss()
    }

    @ViewBuilder
    private func profileContent(_ profile: SSHProfile) -> some View {
        let state = store.tmuxDiscovery[profile.id] ?? TmuxDiscoveryState()

        List {
            if store.profiles.count > 1 {
                Section {
                    Picker("Host", selection: $chosenProfileID) {
                        ForEach(store.profiles) { candidate in
                            Text(candidate.displayName).tag(Optional(candidate.id))
                        }
                    }
                    .onAppear {
                        if chosenProfileID == nil { chosenProfileID = profile.id }
                    }
                }
            }

            if state.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Asking \(profile.displayName) for tmux sessions…")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.mutedLabel)
                    }
                }
            }

            switch state.result {
            case nil:
                if !state.isLoading {
                    quietStateSection(
                        symbol: "rectangle.stack",
                        text: "Refresh to look for tmux sessions on \(profile.displayName)."
                    )
                }
            case .tmuxNotInstalled:
                quietStateSection(
                    symbol: "circle.slash",
                    text: "tmux isn’t installed on \(profile.displayName). That’s a normal state — there is simply nothing to browse."
                )
            case .noServer:
                quietStateSection(
                    symbol: "moon.zzz",
                    text: "No tmux server is running on \(profile.displayName). Start a session there and refresh."
                )
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Button("Try Again") { refresh(profile) }
                        .font(.system(size: 12, weight: .semibold))
                }
            case .sessions(let sessions):
                if sessions.isEmpty {
                    quietStateSection(
                        symbol: "moon.zzz",
                        text: "The tmux server on \(profile.displayName) has no sessions."
                    )
                } else {
                    sessionsSections(sessions, profile: profile, refreshedAt: state.refreshedAt)
                }
            }
        }
    }

    private struct AgentCandidate: Identifiable {
        let session: TmuxSessionSummary
        let pane: TmuxPane

        var id: String { pane.paneID }
    }

    @ViewBuilder
    private func sessionsSections(
        _ sessions: [TmuxSessionSummary],
        profile: SSHProfile,
        refreshedAt: Date?
    ) -> some View {
        let candidates = sessions.flatMap { session in
            session.agentPanes.map { AgentCandidate(session: session, pane: $0) }
        }

        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { candidate in
                    Button {
                        open(candidate.session, profile: profile)
                    } label: {
                        agentRow(candidate.pane, session: candidate.session)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Claude / Codex")
            } footer: {
                Text("Detection reads the pane’s command and title, so “likely” rows are a guess. Panes only show as confirmed when an optional @modot_agent tmux option was set by a hook you installed yourself.")
            }
        }

        Section {
            ForEach(sessions) { session in
                Button {
                    open(session, profile: profile)
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tmux.browser.session.\(session.sessionID)")
            }
        } header: {
            Text("Sessions")
        } footer: {
            if let refreshedAt {
                Text("Updated \(refreshedAt.formatted(date: .omitted, time: .standard)). Opening a session attaches it in a terminal tab; an already-open tab is reused.")
            }
        }
    }

    private func quietStateSection(symbol: String, text: String) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 22)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.mutedLabel)
            }
            .padding(.vertical, 2)
        }
    }

    private func sessionRow(_ session: TmuxSessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.isAttached ? "rectangle.stack.fill" : "rectangle.stack")
                .foregroundStyle(session.isAttached ? theme.tailnet : theme.mutedLabel)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.label)
                Text(sessionSubtitle(session))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.mutedLabel)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.mutedLabel)
        }
        .contentShape(Rectangle())
    }

    private func sessionSubtitle(_ session: TmuxSessionSummary) -> String {
        var parts = [
            "\(session.windowCount) window\(session.windowCount == 1 ? "" : "s")",
            session.isAttached ? "attached" : "detached",
        ]
        if let path = session.panes.first(where: \.paneActive)?.currentPath, !path.isEmpty {
            parts.append(path)
        }
        return parts.joined(separator: " · ")
    }

    private func agentRow(_ pane: TmuxPane, session: TmuxSessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.tailnet)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pane.agentDetection.kind?.label ?? "Agent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.label)
                    Text(pane.agentDetection.isCertain ? "confirmed" : "likely")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pane.agentDetection.isCertain ? theme.background : theme.mutedLabel)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            pane.agentDetection.isCertain ? AnyShapeStyle(theme.tailnet) : AnyShapeStyle(.clear),
                            in: Capsule()
                        )
                        .overlay {
                            if !pane.agentDetection.isCertain {
                                Capsule().stroke(theme.border, lineWidth: 0.75)
                            }
                        }
                }
                Text("\(session.name) · window \(pane.windowIndex) · \(pane.currentCommand)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.mutedLabel)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.mutedLabel)
        }
        .contentShape(Rectangle())
    }
}
