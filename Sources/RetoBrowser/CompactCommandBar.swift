import SwiftUI

struct CompactCommandBar: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.commandBarCollapsed {
                    collapsedBar
                } else {
                    expandedBar
                }
            }
            .frame(height: 28)

            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)

            bookmarkBar
                .frame(height: 19.5)
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
        HStack(spacing: 2) {
            AppBarIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Open sidebar") {
                store.sidebarVisible = true
            }

            Text(store.activeWorkspace.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)

            Text("\(store.activeWorkspace.tabs.count)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(theme.mutedLabel)

            Spacer(minLength: 4)

            AppBarIconButton(systemName: "command", accessibilityLabel: "Open command palette") {
                store.commandPalettePresented = true
            }

            if store.activeWorkspace.splitEnabled {
                PaneFocusControl(store: store)
            }

            AppBarIconButton(systemName: "chevron.down", accessibilityLabel: "Expand command bar") {
                store.toggleCommandBar()
            }
        }
        .padding(.horizontal, 4)
    }

    private var expandedBar: some View {
        HStack(spacing: horizontalSizeClass == .compact ? 2 : 3) {
            AppBarIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Open sidebar") {
                store.sidebarVisible = true
            }
            .accessibilityIdentifier("browser.sidebar.open")

            CompactAddressField(
                store: store,
                terminalStore: terminalStore,
                fillsAvailableWidth: true
            )

            CompactNavigationControl(store: store)

            AppBarIconButton(systemName: "plus", accessibilityLabel: "New tab") {
                store.addTab()
            }

            aiControl
            hamburgerMenu
        }
        .padding(.horizontal, 4)
    }

    private var barHeight: CGFloat {
        48
    }

    private var bookmarkBar: some View {
        HStack(spacing: 0) {
            AppBarIconButton(
                systemName: store.isBookmarked(store.currentPageURL) ? "star.fill" : "star",
                accessibilityLabel: store.isBookmarked(store.currentPageURL) ? "Remove bookmark" : "Bookmark this page"
            ) {
                store.quickToggleBookmark()
            }

            Rectangle()
                .fill(theme.border)
                .frame(width: 0.5, height: 12)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    if store.pinnedBookmarks.isEmpty {
                        Text("BOOKMARKS")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(theme.mutedLabel)
                    } else {
                        ForEach(store.pinnedBookmarks) { bookmark in
                            Button {
                                store.openBookmark(bookmark.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(bookmarkStatusColor(bookmark.id))
                                        .frame(width: 4, height: 4)
                                    Text(bookmark.title)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(theme.label)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Unpin bookmark", systemImage: "pin.slash") {
                                    store.toggleBookmarkPin(bookmark.id)
                                }
                                Button("Delete bookmark", systemImage: "trash", role: .destructive) {
                                    store.removeBookmark(bookmark.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            Menu {
                bookmarkMenuItems
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 24, height: 19)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All bookmarks")
        }
    }

    private func bookmarkStatusColor(_ bookmarkID: UUID) -> Color {
        switch store.statusMonitor.state(for: bookmarkID) {
        case .online: .green
        case .offline: .red
        case .checking: .orange
        case .idle: theme.mutedLabel.opacity(0.5)
        }
    }

    @ViewBuilder
    private var workspaceMenuItems: some View {
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
    }

    private var aiControl: some View {
        AppBarIconButton(
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

    // Everything that used to crowd the bar lives here now.
    private var hamburgerMenu: some View {
        let session = store.session(for: store.activePane)
        let currentTabID = store.selectedTabID(for: store.activePane)
        let currentTab = store.selectedTab(for: store.activePane)

        return Menu {
            Section {
                Button {
                    store.quickToggleBookmark()
                } label: {
                    if store.isBookmarked(session.currentURL) {
                        Label("Remove bookmark", systemImage: "star.fill")
                    } else {
                        Label("Bookmark this page", systemImage: "star")
                    }
                }
                .disabled(session.currentURL == nil)

                Button("Bookmark with details…", systemImage: "slider.horizontal.3") {
                    store.presentedSheet = .addBookmark(
                        title: session.title,
                        url: session.currentURL?.absoluteString ?? ""
                    )
                }
                .disabled(session.currentURL == nil)

                bookmarksSubmenu
            }

            Section {
                Button(
                    store.activeWorkspace.splitEnabled ? "Close split view" : "Split view",
                    systemImage: "rectangle.split.2x1"
                ) {
                    store.toggleSplit()
                }

                Button(
                    terminalStore.presentedSurface == nil ? "SSH terminal" : "Hide SSH terminal",
                    systemImage: "terminal"
                ) {
                    terminalStore.toggleSurface()
                }

                Button("Command palette", systemImage: "command") { store.commandPalettePresented = true }
            }

            Section("Current tab") {
                Button(currentTab.isPinned ? "Unpin tab" : "Pin tab", systemImage: "pin") {
                    store.toggleTabPin(currentTabID)
                }

                Menu("Move to group") {
                    Button("None") { store.assignTab(currentTabID, to: nil) }
                    ForEach(store.groups) { group in
                        Button(group.name) { store.assignTab(currentTabID, to: group.id) }
                    }
                }

                Menu("Move to stack") {
                    Button("None") { store.assignTab(currentTabID, toStack: nil) }
                    ForEach(store.activeWorkspace.tabStacks) { stack in
                        Button(stack.name) { store.assignTab(currentTabID, toStack: stack.id) }
                    }
                    Divider()
                    Button("New stack…") { store.presentedSheet = .createTabStack }
                }

                Button("Archive tab", systemImage: "archivebox") {
                    store.archiveTab(currentTabID)
                }

                Button("Close tab", systemImage: "xmark", role: .destructive) {
                    store.closeTab(currentTabID)
                }
            }

            Section {
                Menu {
                    workspaceMenuItems
                } label: {
                    Label("Workspace · \(store.activeWorkspace.name)", systemImage: "square.grid.2x2")
                }

                Button("Services sidebar", systemImage: "sidebar.left") { store.sidebarVisible = true }
            }

            Section {
                Button("Site settings", systemImage: "shield.lefthalf.filled") { store.presentedSheet = .siteSettings }
                Button("Page tools", systemImage: "wrench.and.screwdriver") { store.presentedSheet = .pageTools }
                Button("Developer tools", systemImage: "chevron.left.forwardslash.chevron.right") {
                    store.presentedSheet = .developerTools
                }
                Button("Reopen closed tab", systemImage: "clock.arrow.circlepath") { store.reopenLastClosedTab() }
                    .disabled(store.recentlyClosedTabs.isEmpty)
                Button("Tab history", systemImage: "tray.full") { store.presentedSheet = .tabArchive }
                Button("Downloads", systemImage: "arrow.down.circle") { store.presentedSheet = .downloads }
                Button("AI settings", systemImage: "sparkles") { aiStore.settingsPresented = true }
                Button("Refresh service status", systemImage: "wave.3.right") { store.refreshServiceStatuses() }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .accessibilityLabel("Browser menu")
        .accessibilityIdentifier("browser.menu")
    }

    private var bookmarksSubmenu: some View {
        Menu {
            bookmarkMenuItems
        } label: {
            Label("Bookmarks", systemImage: "bookmark")
        }
    }

    @ViewBuilder
    private var bookmarkMenuItems: some View {
        if store.visibleBookmarks.isEmpty {
            Text("No bookmarks")
        } else {
            ForEach(store.groups) { group in
                let groupBookmarks = store.visibleBookmarks.filter { $0.groupID == group.id }
                if !groupBookmarks.isEmpty {
                    Section(group.name) {
                        ForEach(groupBookmarks) { bookmark in
                            Button(bookmark.title) { store.openBookmark(bookmark.id) }
                        }
                    }
                }
            }

            let ungrouped = store.visibleBookmarks.filter { $0.groupID == nil }
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
    }
}

enum BrowserRootCoordinateSpace {
    static let name = "browser-root"
}

struct PanePlacementChooser: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore
    let tabID: UUID

    var body: some View {
        let axis = store.activeWorkspace.splitAxis

        HStack(spacing: 6) {
            paneButton(
                .primary,
                systemName: axis == .horizontal ? "rectangle.lefthalf.filled" : "rectangle.tophalf.filled"
            )
            paneButton(
                .secondary,
                systemName: axis == .horizontal ? "rectangle.righthalf.filled" : "rectangle.bottomhalf.filled"
            )
        }
        .padding(8)
        .presentationBackground(theme.background)
    }

    private func paneButton(_ pane: BrowserPane, systemName: String) -> some View {
        Button {
            store.placeTab(tabID, in: pane)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                Text(store.activeWorkspace.splitAxis.badge(for: pane))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .frame(width: 52, height: 46)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .accessibilityLabel(pane == .primary ? "Show in first pane" : "Show in second pane")
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
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(session.hasOnlySecureContent ? theme.tailnet : theme.mutedLabel)

            TextField("Address, search, or ssh://", text: $session.address)
                .font(.system(size: 10))
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

            if session.isLoading {
                reloadButton(systemName: "xmark", label: "Stop loading") {
                    session.stopLoading()
                }
            } else if session.currentURL != nil {
                reloadButton(systemName: "arrow.clockwise", label: "Reload page") {
                    session.reload()
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(
            minWidth: fillsAvailableWidth ? 100 : 216,
            idealWidth: 246,
            maxWidth: fillsAvailableWidth ? .infinity : 246,
            minHeight: 24,
            maxHeight: 24
        )
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .accessibilityIdentifier("browser.address")
    }

    private func reloadButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.mutedLabel)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CompactNavigationControl: View {
    let store: WorkspaceBrowserStore

    var body: some View {
        let session = store.session(for: store.activePane)

        HStack(spacing: 2) {
            navigationButton("chevron.backward", label: "Back", disabled: !session.canGoBack) {
                session.goBack()
            }
            navigationButton("chevron.forward", label: "Forward", disabled: !session.canGoForward) {
                session.goForward()
            }
        }
    }

    private func navigationButton(
        _ systemName: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct PaneFocusControl: View {
    let store: WorkspaceBrowserStore

    var body: some View {
        Picker("Active pane", selection: Binding(
            get: { store.activePane },
            set: { store.setActivePane($0) }
        )) {
            ForEach(BrowserPane.allCases) { pane in
                Text(store.activeWorkspace.splitAxis.badge(for: pane)).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 64)
        .accessibilityLabel("Active split pane")
    }
}

private struct AppBarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .tint(selected ? Color.accentColor : nil)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
