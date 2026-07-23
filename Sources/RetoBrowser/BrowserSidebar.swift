import SwiftUI

struct BrowserSidebar: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    workspaceSection
                    sectionDivider
                    activeTabsSection
                    sectionDivider

                    if !store.pinnedBookmarks.isEmpty {
                        sectionLabel("Pinned", actionSystemName: nil, action: nil)
                        ForEach(store.pinnedBookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                        sectionDivider
                    }

                    sshSection
                    sectionDivider

                    ForEach(store.groups) { group in
                        groupSection(group)
                        sectionDivider
                    }

                    ungroupedSection
                }
            }

            sidebarFooter
        }
        .background(theme.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.border).frame(width: 0.5)
        }
        .safeAreaPadding(.bottom, 6)
        // TerminalWorkspaceStore has no reference back to WorkspaceBrowserStore
        // (see D1.2 — no two-way dependency), so this is the one-way "current
        // workspace" setter the design calls for, mirrored the same way the
        // view layer already hands layoutIsCompact to WorkspaceBrowserStore.
        // The sidebar is the one place both stores already meet: workspace
        // switching, group editing, and the SSH profile editor all launch
        // from here.
        .onAppear { syncTerminalWorkspaceContext() }
        .onChange(of: store.activeWorkspaceID) { _, _ in syncTerminalWorkspaceContext() }
        .onChange(of: store.workspaces) { _, _ in syncTerminalWorkspaceContext() }
        .onChange(of: store.groups) { _, _ in syncTerminalWorkspaceContext() }
    }

    private func syncTerminalWorkspaceContext() {
        terminalStore.setActiveWorkspace(store.activeWorkspace.isPrivate ? nil : store.activeWorkspaceID)
        terminalStore.availableWorkspaces = store.workspaces.filter { !$0.isPrivate }.map {
            TerminalWorkspaceSummary(id: $0.id, name: $0.name)
        }
        terminalStore.availableGroups = store.groups
    }

    private var sidebarHeader: some View {
        HStack {
            Text("SERVICES")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(theme.mutedLabel)

            Spacer()

            CompactIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh service status") {
                store.refreshServiceStatuses()
            }

            CompactIconButton(systemName: "command", accessibilityLabel: "Open command palette") {
                store.commandPalettePresented = true
                store.sidebarVisible = false
            }

            CompactIconButton(systemName: "xmark", accessibilityLabel: "Close sidebar") {
                store.sidebarVisible = false
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    private var workspaceSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Workspaces", actionSystemName: "plus") {
                store.presentedSheet = .addWorkspace
            }

            ForEach(store.workspaces) { workspace in
                Button {
                    store.selectWorkspace(workspace.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: workspace.isPrivate
                            ? "hand.raised.fill"
                            : (workspace.id == store.activeWorkspaceID ? "circle.inset.filled" : "circle"))
                            .font(.system(size: workspace.isPrivate ? 11 : 9))
                            .foregroundStyle(workspace.isPrivate
                                ? Color.purple
                                : (workspace.id == store.activeWorkspaceID ? theme.tailnet : theme.mutedLabel))

                        Text(workspace.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.label)

                        Spacer()

                        Text("\(workspace.tabs.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.mutedLabel)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(workspace.id == store.activeWorkspaceID ? theme.raisedBackground : Color.clear)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete workspace", systemImage: "trash", role: .destructive) {
                        // D1.5 decision: reset profiles scoped to this
                        // workspace back to shared (nil) rather than delete a
                        // server the user configured — the same reasoning
                        // that already governs bookmarks' nil-means-shared
                        // default.
                        terminalStore.resetWorkspaceScopedProfiles(workspace.id)
                        store.deleteWorkspace(workspace.id)
                    }
                    .disabled(!store.canDeleteWorkspace(workspace.id))
                }
            }
        }
    }

    private var activeTabsSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Tabs", actionSystemName: "plus") {
                store.addTab()
            }

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(store.orderedTabs) { tab in
                        compactTabLine(tab)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .frame(height: 30)
        }
    }

    private func compactTabLine(_ tab: BrowserTabRecord) -> some View {
        let active = store.selectedTabID(for: store.activePane) == tab.id
        let dragged = store.tabDragState?.tabID == tab.id

        return HStack(spacing: 3) {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
            } else if tab.stackID != nil {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 7))
            }

            Text(tab.title)
                .font(.system(size: 9, weight: active ? .semibold : .regular))
                .lineLimit(1)

            if let pane = store.paneShowing(tab.id), store.activeWorkspace.splitEnabled {
                Text(store.activeWorkspace.splitAxis.badge(for: pane))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.mutedLabel)
            }
        }
        .foregroundStyle(active ? theme.label : theme.mutedLabel)
        .padding(.horizontal, 7)
        .frame(minWidth: 48, maxWidth: 124, minHeight: 28, maxHeight: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(active ? theme.accent : theme.border.opacity(0.55))
                .frame(height: active ? 1.5 : 0.5)
        }
        .opacity(dragged ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            store.handleTabTap(tab.id)
            if store.panePlacementPromptTabID == nil {
                store.sidebarVisible = false
            }
        }
        .tabDragGesture(store: store, tabID: tab.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab.title)
        .contextMenu {
            Button(tab.isPinned ? "Unpin tab" : "Pin tab", systemImage: "pin") {
                store.toggleTabPin(tab.id)
            }
            Button("Archive tab", systemImage: "archivebox") { store.archiveTab(tab.id) }
            Button("Close tab", systemImage: "xmark", role: .destructive) { store.closeTab(tab.id) }
        }
        .popover(
            isPresented: Binding(
                get: { store.panePlacementPromptTabID == tab.id },
                set: { if !$0 { store.panePlacementPromptTabID = nil } }
            ),
            arrowEdge: .top
        ) {
            PanePlacementChooser(store: store, tabID: tab.id)
                .presentationCompactAdaptation(.popover)
        }
        .animation(.snappy(duration: 0.18), value: dragged)
    }

    private func groupSection(_ group: ServiceGroup) -> some View {
        let bookmarks = store.visibleBookmarks.filter { $0.groupID == group.id && !$0.isPinned }
        let profiles = terminalStore.visibleProfiles.filter { $0.groupID == group.id }

        return VStack(spacing: 0) {
            groupHeader(group)

            if bookmarks.isEmpty && profiles.isEmpty {
                emptyGroupRow
            } else {
                ForEach(bookmarks) { bookmark in bookmarkRow(bookmark) }
                ForEach(profiles) { profile in sshProfileRow(profile) }
            }
        }
    }

    private var ungroupedSection: some View {
        let bookmarks = store.visibleBookmarks.filter { $0.groupID == nil && !$0.isPinned }

        return VStack(spacing: 0) {
            sectionLabel("Other", actionSystemName: nil, action: nil)
            ForEach(bookmarks) { bookmark in bookmarkRow(bookmark) }
        }
    }

    private var sshSection: some View {
        VStack(spacing: 0) {
            sectionLabel("SSH", actionSystemName: "plus") {
                store.sidebarVisible = false
                terminalStore.presentProfileEditor()
            }

            Button {
                store.sidebarVisible = false
                terminalStore.presentTerminal()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .frame(width: 18)
                    Text("Open terminal")
                    Spacer()
                    if !terminalStore.tabs.isEmpty {
                        Text("\(terminalStore.tabs.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.mutedLabel)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.label)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.ssh.open")

            // Profiles assigned to a group are listed under that group
            // instead (see groupSection), so only ungrouped ones show here —
            // the same split bookmarks already use between their group
            // sections and the "Other" section.
            let ungroupedProfiles = terminalStore.visibleProfiles.filter { $0.groupID == nil }

            if ungroupedProfiles.isEmpty {
                Button {
                    store.sidebarVisible = false
                    terminalStore.presentProfileEditor()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .frame(width: 18)
                        Text("Add SSH connection")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.mutedLabel)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.label)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.ssh.add")
            } else {
                ForEach(ungroupedProfiles) { profile in
                    Button {
                        store.sidebarVisible = false
                        terminalStore.openTab(profileID: profile.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: profile.usesTmux ? "rectangle.stack" : "server.rack")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(profile.endpoint)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(theme.mutedLabel)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(theme.mutedLabel)
                        }
                        .foregroundStyle(theme.label)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.sidebarVisible = false
                    terminalStore.presentProfiles()
                } label: {
                    Label("Manage connections", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.mutedLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 42)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tabStacksSection: some View {
        VStack(spacing: 0) {
            sectionLabel("Tab stacks", actionSystemName: "plus") {
                store.presentedSheet = .createTabStack
            }
            ForEach(store.activeWorkspace.tabStacks) { stack in
                let tabs = store.activeWorkspace.tabs.filter { $0.stackID == stack.id }
                Button { store.toggleTabStack(stack.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: stack.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text(stack.name).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(tabs.count)").font(.caption.monospacedDigit()).foregroundStyle(theme.mutedLabel)
                    }
                    .foregroundStyle(theme.label)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete stack", systemImage: "trash", role: .destructive) {
                        store.deleteTabStack(stack.id)
                    }
                }
                if !stack.isCollapsed {
                    ForEach(tabs) { tab in tabRow(tab) }
                }
            }
        }
    }

    private func tabRow(_ tab: BrowserTabRecord) -> some View {
        Button {
            store.selectTab(tab.id)
            store.sidebarVisible = false
        } label: {
            serviceRow(
                icon: tab.isPinned ? "pin.fill" : "rectangle",
                title: tab.title,
                subtitle: URL(string: tab.urlString)?.host(),
                tint: tab.isPinned ? theme.tailnet : theme.mutedLabel,
                status: nil,
                hibernated: store.isTabHibernated(tab.id)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tab.isPinned ? "Unpin tab" : "Pin tab", systemImage: "pin") {
                store.toggleTabPin(tab.id)
            }

            Menu("Move to group") {
                Button("None") { store.assignTab(tab.id, to: nil) }
                ForEach(store.groups) { group in
                    Button(group.name) { store.assignTab(tab.id, to: group.id) }
                }
            }

            Menu("Move to stack") {
                Button("None") { store.assignTab(tab.id, toStack: nil) }
                ForEach(store.activeWorkspace.tabStacks) { stack in
                    Button(stack.name) { store.assignTab(tab.id, toStack: stack.id) }
                }
                Divider()
                Button("New stack…") { store.presentedSheet = .createTabStack }
            }

            Button("Archive tab", systemImage: "archivebox") { store.archiveTab(tab.id) }

            Button("Close tab", systemImage: "xmark", role: .destructive) {
                store.closeTab(tab.id)
            }
        }
    }

    private func bookmarkRow(_ bookmark: ServiceBookmark) -> some View {
        Button {
            store.openBookmark(bookmark.id)
        } label: {
            serviceRow(
                icon: bookmark.isPinned ? "star.fill" : "bookmark",
                title: bookmark.title,
                subtitle: bookmark.url?.host(),
                tint: bookmark.isPinned ? theme.tailnet : theme.mutedLabel,
                status: store.statusMonitor.state(for: bookmark.id),
                hibernated: false
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(bookmark.isPinned ? "Unpin bookmark" : "Pin bookmark", systemImage: "pin") {
                store.toggleBookmarkPin(bookmark.id)
            }

            Menu("Move to group") {
                Button("None") { store.assignBookmark(bookmark.id, to: nil) }
                ForEach(store.groups) { group in
                    Button(group.name) { store.assignBookmark(bookmark.id, to: group.id) }
                }
            }

            Menu("Workspace") {
                Button {
                    store.assignBookmark(bookmark.id, toWorkspace: nil)
                } label: {
                    if bookmark.workspaceID == nil {
                        Label("All workspaces", systemImage: "checkmark")
                    } else {
                        Text("All workspaces")
                    }
                }
                ForEach(store.workspaces) { workspace in
                    Button {
                        store.assignBookmark(bookmark.id, toWorkspace: workspace.id)
                    } label: {
                        if bookmark.workspaceID == workspace.id {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
            }

            Button(bookmark.monitorsStatus ? "Stop status checks" : "Monitor status", systemImage: "wave.3.right") {
                store.toggleBookmarkMonitoring(bookmark.id)
            }

            Button("Delete bookmark", systemImage: "trash", role: .destructive) {
                store.removeBookmark(bookmark.id)
            }
        }
    }

    /// A group's SSH entry, styled like a bookmark row but reusing the
    /// terminal/server iconography already used elsewhere for SSH profiles
    /// (see `sshSection` below) rather than inventing new symbols.
    private func sshProfileRow(_ profile: SSHProfile) -> some View {
        Button {
            store.sidebarVisible = false
            terminalStore.openTab(profileID: profile.id)
        } label: {
            serviceRow(
                icon: profile.usesTmux ? "rectangle.stack" : "server.rack",
                title: profile.displayName,
                subtitle: profile.endpoint,
                tint: theme.mutedLabel,
                status: nil,
                hibernated: false
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Move to group") {
                Button("None") { terminalStore.assignProfile(profile.id, toGroup: nil) }
                ForEach(store.groups) { group in
                    Button(group.name) { terminalStore.assignProfile(profile.id, toGroup: group.id) }
                }
            }

            Menu("Workspace") {
                Button {
                    terminalStore.assignProfile(profile.id, toWorkspace: nil)
                } label: {
                    if profile.workspaceID == nil {
                        Label("All workspaces", systemImage: "checkmark")
                    } else {
                        Text("All workspaces")
                    }
                }
                ForEach(store.workspaces) { workspace in
                    Button {
                        terminalStore.assignProfile(profile.id, toWorkspace: workspace.id)
                    } label: {
                        if profile.workspaceID == workspace.id {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
            }

            Button("Delete profile", systemImage: "trash", role: .destructive) {
                terminalStore.deleteProfile(profile.id)
            }
        }
    }

    private func serviceRow(
        icon: String,
        title: String,
        subtitle: String?,
        tint: Color,
        status: ServiceReachability?,
        hibernated: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.mutedLabel)
                        .lineLimit(1)
                }
            }

            Spacer()

            if hibernated {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.mutedLabel)
                    .accessibilityLabel("Hibernated tab")
            }

            if let status {
                statusBadge(status)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.mutedLabel.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusBadge(_ status: ServiceReachability) -> some View {
        switch status {
        case .idle:
            Circle().fill(theme.mutedLabel.opacity(0.45)).frame(width: 7, height: 7)
        case .checking:
            ProgressView().controlSize(.mini)
        case .online(let latency, _):
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(latency)ms").font(.system(size: 8, design: .monospaced)).foregroundStyle(theme.mutedLabel)
            }
            .accessibilityLabel("Online, \(latency) milliseconds")
        case .offline:
            Circle().fill(.red).frame(width: 7, height: 7).accessibilityLabel("Offline")
        }
    }

    private func sectionLabel(
        _ title: String,
        actionSystemName: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.mutedLabel)

            Spacer()

            if let actionSystemName, let action {
                Button(action: action) {
                    Image(systemName: actionSystemName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.mutedLabel)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func groupHeader(_ group: ServiceGroup) -> some View {
        HStack {
            Text(group.name.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.mutedLabel)

            Spacer()

            Menu {
                // D1.4 payoff: restores this group as a working context —
                // its URLs laid into panes and its SSH/tmux profiles opened
                // as terminal tabs — reusing the same addPane/open/openTab
                // APIs a user would drive by hand.
                Button("Open group", systemImage: "rectangle.grid.2x2") {
                    store.openGroup(group.id)
                    for profile in terminalStore.visibleProfiles where profile.groupID == group.id {
                        terminalStore.openTab(profileID: profile.id)
                    }
                    store.sidebarVisible = false
                }

                Button("Delete group", systemImage: "trash", role: .destructive) {
                    // Clears groupID on member profiles the same way
                    // deleteGroup already does for bookmarks and tabs.
                    terminalStore.clearGroup(group.id)
                    store.deleteGroup(group.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var emptyGroupRow: some View {
        Text("No services")
            .font(.system(size: 12))
            .foregroundStyle(theme.mutedLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 42)
            .frame(height: 34)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 0.5)
            .padding(.vertical, 4)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            if store.activeWorkspace.splitEnabled {
                HStack(spacing: 10) {
                    Text("SPLIT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(theme.mutedLabel)

                    Spacer()

                    Picker("Split ratio", selection: splitRatioSelection) {
                        ForEach([0.35, 0.5, 0.65], id: \.self) { ratio in
                            Text("\(Int(ratio * 100))").tag(ratio)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
            }

            HStack(spacing: 4) {
                Button("Bookmark", systemImage: "bookmark") {
                    let session = store.session(for: store.activePane)
                    store.presentedSheet = .addBookmark(
                        title: session.title,
                        url: session.currentURL?.absoluteString ?? session.address
                    )
                }
                .disabled(store.session(for: store.activePane).currentURL == nil)

                Spacer()

                Button("Group", systemImage: "folder.badge.plus") {
                    store.presentedSheet = .addGroup
                }
            }
            .frame(height: 48)

            HStack(spacing: 8) {
                Button("History", systemImage: "clock.arrow.circlepath") {
                    store.presentedSheet = .tabArchive
                }
                Spacer()
                Button("Downloads", systemImage: "arrow.down.circle") {
                    store.presentedSheet = .downloads
                }
            }
            .frame(height: 38)

            Rectangle().fill(theme.border).frame(height: 0.5)

            HStack(spacing: 8) {
                Button {
                    aiStore.present()
                    store.sidebarVisible = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AI Assistant")
                            Text(aiStore.settings.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.mutedLabel)
                        }
                        Spacer()
                    }
                    .foregroundStyle(theme.label)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(aiStore.settings.displayName) AI assistant")
                .accessibilityIdentifier("sidebar.ai.open")

                Button {
                    aiStore.settingsPresented = true
                    store.sidebarVisible = false
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("AI settings")
                .accessibilityIdentifier("sidebar.ai.settings")
            }
            .frame(height: 48)

            Button {
                terminalStore.toggleLauncher()
                store.sidebarVisible = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .frame(width: 18)
                    Text("Floating Terminal Button")
                    Spacer()
                    if terminalStore.launcherEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.tailnet)
                    }
                }
                .foregroundStyle(theme.label)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 44)
            .accessibilityLabel(terminalStore.launcherEnabled ? "Hide terminal button" : "Show terminal button")
            .accessibilityIdentifier("sidebar.terminal-toggle")
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    private var splitRatioSelection: Binding<Double> {
        Binding(
            get: {
                [0.35, 0.5, 0.65].min { lhs, rhs in
                    abs(lhs - store.activeWorkspace.splitRatio) < abs(rhs - store.activeWorkspace.splitRatio)
                } ?? 0.5
            },
            set: { store.setSplitRatio($0) }
        )
    }
}
