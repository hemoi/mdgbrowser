import SwiftUI

struct CompactCommandBar: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    var body: some View {
        Group {
            if store.commandBarCollapsed {
                collapsedBar
            } else if horizontalSizeClass == .compact {
                compactExpandedBar
            } else {
                regularExpandedBar
            }
        }
        .frame(height: barHeight)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)
        }
    }

    private var collapsedBar: some View {
        HStack(spacing: 4) {
            CompactIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Open sidebar") {
                store.sidebarVisible = true
            }

            Text(store.activeWorkspace.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text("\(store.activeWorkspace.tabs.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(theme.mutedLabel)

            Spacer(minLength: 4)

            CompactIconButton(systemName: "command", accessibilityLabel: "Open command palette") {
                store.commandPalettePresented = true
            }

            terminalControl

            if store.activeWorkspace.splitEnabled {
                PaneFocusControl(store: store)
            }

            CompactIconButton(systemName: "chevron.down", accessibilityLabel: "Expand command bar") {
                store.toggleCommandBar()
            }
        }
        .padding(.horizontal, 6)
    }

    private var regularExpandedBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                CompactIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Open sidebar") {
                    store.sidebarVisible = true
                }

                workspaceMenu

                barDivider
                TabStrip(store: store)

                CompactIconButton(systemName: "plus", accessibilityLabel: "New tab") {
                    store.addTab()
                }

                barDivider
                CompactNavigationControl(store: store)
                CompactAddressField(store: store, terminalStore: terminalStore)

                privacyShield
                pageNoteControl
                aiControl
                featureMenu
                terminalControl

                bookmarkControl
                pinnedBookmarks
                allBookmarksMenu

                barDivider

                if store.activeWorkspace.splitEnabled {
                    PaneFocusControl(store: store)
                }

                CompactIconButton(
                    systemName: "rectangle.split.2x1",
                    accessibilityLabel: store.activeWorkspace.splitEnabled ? "Close split view" : "Open split view",
                    selected: store.activeWorkspace.splitEnabled
                ) {
                    store.toggleSplit()
                }

                CompactIconButton(systemName: "chevron.up", accessibilityLabel: "Collapse command bar") {
                    store.toggleCommandBar()
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var compactExpandedBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                CompactIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Open sidebar") {
                    store.sidebarVisible = true
                }
                .accessibilityIdentifier("browser.sidebar.open")

                workspaceMenu

                ScrollView(.horizontal) {
                    TabStrip(store: store)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)

                CompactIconButton(systemName: "plus", accessibilityLabel: "New tab") {
                    store.addTab()
                }

                terminalControl
            }
            .padding(.horizontal, 6)
            .frame(height: 38)

            HStack(spacing: 4) {
                CompactNavigationControl(store: store)
                CompactAddressField(
                    store: store,
                    terminalStore: terminalStore,
                    fillsAvailableWidth: true
                )
                bookmarkControl
                aiControl
                featureMenu
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
        }
    }

    private var terminalControl: some View {
        CompactIconButton(
            systemName: terminalStore.presentedSurface == nil ? "terminal" : "terminal.fill",
            accessibilityLabel: terminalStore.presentedSurface == nil ? "Open SSH terminal" : "Hide SSH terminal",
            selected: terminalStore.presentedSurface != nil
        ) {
            terminalStore.toggleSurface()
        }
        .accessibilityIdentifier("browser.ssh.open")
    }

    private var barHeight: CGFloat {
        if store.commandBarCollapsed { return 40 }
        return horizontalSizeClass == .compact ? 76 : 44
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(store.workspaces) { workspace in
                Button {
                    store.selectWorkspace(workspace.id)
                } label: {
                    if workspace.id == store.activeWorkspaceID {
                        Label(workspace.name, systemImage: "checkmark")
                    } else {
                        Text(workspace.name)
                    }
                }
            }

            Divider()

            Button("New workspace", systemImage: "plus") {
                store.presentedSheet = .addWorkspace
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.activeWorkspace.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.label)
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var bookmarkControl: some View {
        let session = store.session(for: store.activePane)
        return CompactIconButton(
            systemName: store.isBookmarked(session.currentURL) ? "star.fill" : "star",
            accessibilityLabel: "Toggle bookmark",
            selected: store.isBookmarked(session.currentURL),
            disabled: session.currentURL == nil
        ) {
            store.quickToggleBookmark()
        }
        .contextMenu {
            if let url = session.currentURL {
                Button("Add with details", systemImage: "slider.horizontal.3") {
                    store.presentedSheet = .addBookmark(
                        title: session.title,
                        url: url.absoluteString
                    )
                }
            }
        }
    }

    private var privacyShield: some View {
        let settings = store.settings(for: store.currentPageURL)
        return CompactIconButton(
            systemName: settings.blockerEnabled ? "shield.lefthalf.filled" : "shield.slash",
            accessibilityLabel: "Site privacy settings",
            selected: settings.blockerEnabled,
            disabled: store.currentPageURL == nil
        ) {
            store.presentedSheet = .siteSettings
        }
    }

    private var pageNoteControl: some View {
        CompactIconButton(
            systemName: store.currentPageNote == nil ? "note.text" : "note.text.badge.plus",
            accessibilityLabel: "Page note",
            selected: store.currentPageNote != nil
        ) {
            store.presentedSheet = .pageNote
        }
    }

    private var aiControl: some View {
        CompactIconButton(
            systemName: aiStore.isPresented ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
            accessibilityLabel: aiStore.isPresented ? "Hide AI assistant" : "Open AI assistant",
            selected: aiStore.isPresented
        ) {
            if aiStore.isPresented {
                aiStore.dismiss()
            } else {
                aiStore.present()
            }
        }
        .accessibilityIdentifier("browser.ai.open")
    }

    private var featureMenu: some View {
        Menu {
            Button("Command palette", systemImage: "command") { store.commandPalettePresented = true }
            Button("AI assistant", systemImage: "sparkles.rectangle.stack") { aiStore.present() }
            Button("AI settings", systemImage: "sparkles") { aiStore.settingsPresented = true }
            Button("Page tools", systemImage: "wrench.and.screwdriver") { store.presentedSheet = .pageTools }
            Button("Site settings", systemImage: "switch.2") { store.presentedSheet = .siteSettings }
            Button("Page note", systemImage: "note.text") { store.presentedSheet = .pageNote }
            Divider()
            Button("Reopen closed tab", systemImage: "clock.arrow.circlepath") { store.reopenLastClosedTab() }
                .disabled(store.recentlyClosedTabs.isEmpty)
            Button("Archive current tab", systemImage: "archivebox") {
                store.archiveTab(store.selectedTabID(for: store.activePane))
            }
            Button("Tab history", systemImage: "tray.full") { store.presentedSheet = .tabArchive }
            Button("New tab stack", systemImage: "square.stack.3d.up") { store.presentedSheet = .createTabStack }
            Divider()
            Button("Downloads", systemImage: "arrow.down.circle") { store.presentedSheet = .downloads }
            Button("Refresh service status", systemImage: "wave.3.right") { store.refreshServiceStatuses() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browser tools")
    }

    @ViewBuilder
    private var pinnedBookmarks: some View {
        ForEach(store.pinnedBookmarks.prefix(4)) { bookmark in
            Button {
                store.openBookmark(bookmark.id)
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.tailnet)
                        .frame(width: 5, height: 5)
                    Text(bookmark.title)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.label)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.border, lineWidth: 0.75)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var allBookmarksMenu: some View {
        Menu {
            if store.bookmarks.isEmpty {
                Text("No bookmarks")
            } else {
                ForEach(store.groups) { group in
                    let groupBookmarks = store.bookmarks.filter { $0.groupID == group.id }
                    if !groupBookmarks.isEmpty {
                        Section(group.name) {
                            ForEach(groupBookmarks) { bookmark in
                                Button(bookmark.title) { store.openBookmark(bookmark.id) }
                            }
                        }
                    }
                }

                let ungrouped = store.bookmarks.filter { $0.groupID == nil }
                if !ungrouped.isEmpty {
                    Section("Other") {
                        ForEach(ungrouped) { bookmark in
                            Button(bookmark.title) { store.openBookmark(bookmark.id) }
                        }
                    }
                }
            }

            Divider()

            Button("Manage in sidebar", systemImage: "sidebar.left") {
                store.sidebarVisible = true
            }
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All bookmarks")
    }

    private var barDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 0.5, height: 18)
            .padding(.horizontal, 2)
    }
}

private struct TabStrip: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.visibleOrderedTabs) { tab in
                Button {
                    store.selectTab(tab.id)
                } label: {
                    HStack(spacing: 4) {
                        if tab.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                        }

                        if tab.stackID != nil {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 8))
                        }

                        Text(tab.title)
                            .lineLimit(1)

                        if let pane = paneShowing(tab.id) {
                            Text(pane.compactLabel)
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(isActive(tab.id) ? theme.background.opacity(0.8) : theme.mutedLabel)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive(tab.id) ? theme.background : theme.label)
                    .padding(.horizontal, 8)
                    .frame(width: tab.isPinned ? 82 : 102, height: 32)
                    .background(isActive(tab.id) ? theme.accent : theme.raisedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
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

                    Button("Archive tab", systemImage: "archivebox") {
                        store.archiveTab(tab.id)
                    }

                    Divider()

                    Button("Close tab", systemImage: "xmark", role: .destructive) {
                        store.closeTab(tab.id)
                    }
                }
            }
        }
    }

    private func paneShowing(_ tabID: UUID) -> BrowserPane? {
        if store.selectedTabID(for: .primary) == tabID { return .primary }
        if store.activeWorkspace.splitEnabled,
           store.selectedTabID(for: .secondary) == tabID { return .secondary }
        return nil
    }

    private func isActive(_ tabID: UUID) -> Bool {
        store.selectedTabID(for: store.activePane) == tabID
    }
}

private struct CompactAddressField: View {
    @Environment(BrowserTheme.self) private var theme
    @FocusState private var focused: Bool

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    var fillsAvailableWidth = false

    var body: some View {
        let browserSession = store.session(for: store.activePane)
        @Bindable var session = browserSession

        HStack(spacing: 6) {
            Image(systemName: session.hasOnlySecureContent ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.hasOnlySecureContent ? theme.tailnet : theme.mutedLabel)

            TextField("Address, search, or ssh://", text: $session.address)
                .font(.system(size: 11))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit {
                    let submittedAddress = session.address.trimmingCharacters(in: .whitespacesAndNewlines)
                    if submittedAddress.lowercased().hasPrefix("ssh://") {
                        if let profile = SSHProfile.draft(fromSSHAddress: submittedAddress) {
                            terminalStore.presentProfileEditor(profile)
                        } else {
                            session.errorMessage = "Use an SSH address like ssh://user@host or ssh://user@host:port."
                        }
                    } else {
                        store.submitAddress()
                    }
                    focused = false
                }
        }
        .padding(.horizontal, 9)
        .frame(
            minWidth: fillsAvailableWidth ? 120 : 206,
            idealWidth: 206,
            maxWidth: fillsAvailableWidth ? .infinity : 206,
            minHeight: 34,
            maxHeight: 34
        )
        .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(focused ? theme.label.opacity(0.6) : theme.border, lineWidth: 0.75)
        }
        .accessibilityIdentifier("browser.address")
    }
}

private struct CompactNavigationControl: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore

    var body: some View {
        let session = store.session(for: store.activePane)

        HStack(spacing: 0) {
            navigationButton("chevron.backward", label: "Back", disabled: !session.canGoBack) {
                session.goBack()
            }
            navigationButton("chevron.forward", label: "Forward", disabled: !session.canGoForward) {
                session.goForward()
            }
            navigationButton(session.isLoading ? "xmark" : "arrow.clockwise", label: session.isLoading ? "Stop" : "Reload") {
                if session.isLoading {
                    session.stopLoading()
                } else {
                    session.reload()
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.border, lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func navigationButton(
        _ systemName: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 30, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
    }
}

private struct PaneFocusControl: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BrowserPane.allCases) { pane in
                Button(pane.compactLabel) {
                    store.setActivePane(pane)
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(store.activePane == pane ? theme.background : theme.mutedLabel)
                .frame(width: 30, height: 34)
                .background(store.activePane == pane ? theme.accent : Color.clear)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.border, lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("Active split pane")
    }
}
