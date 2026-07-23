import SwiftUI
import UIKit

struct CompactCommandBar: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    var body: some View {
        let appearance = PageChromeAppearance.resolve(store.session(for: store.activePane).pageBackgroundColor)

        return Group {
            if store.commandBarCollapsed {
                collapsedBar
            } else {
                expandedBar
            }
        }
        .frame(height: barHeight)
        // The bar reads as an extension of the page: its tint is the site's
        // own background, and the matching interface style keeps the system
        // label colors on top of it legible.
        .background {
            if let tint = appearance.tint {
                tint
            } else {
                Rectangle().fill(.bar)
            }
        }
        .environment(\.colorScheme, appearance.colorScheme ?? systemColorScheme)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(appearance.tint == nil ? 1 : 0.4))
                .frame(height: 0.5)
        }
        .animation(.easeOut(duration: 0.22), value: appearance)
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

            if store.splitLayout != .single {
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

    // Bookmarks live in the hamburger menu and the sidebar; the bar itself
    // stays a single row.
    private var barHeight: CGFloat {
        38
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

            Section("Layout") {
                Button(
                    store.activeWorkspace.splitEnabled ? "Close split view" : "Split view",
                    systemImage: "rectangle.split.2x1"
                ) {
                    store.toggleSplit()
                }

                Button("Add pane", systemImage: "plus.rectangle") { store.addPane() }
                    .disabled(!store.canAddPane)

                if store.splitLayout != .single {
                    Button("Close this pane", systemImage: "minus.rectangle") {
                        store.closePane(store.activePane)
                    }
                }

                // Compact widths always stack panes, so the axis toggle only
                // makes sense on a regular-width canvas.
                if !store.layoutIsCompact, case .pair = store.splitLayout {
                    Button(
                        store.activeWorkspace.splitAxis == .horizontal ? "Stack panes" : "Side-by-side panes",
                        systemImage: store.activeWorkspace.splitAxis == .horizontal
                            ? "rectangle.split.1x2"
                            : "rectangle.split.2x1"
                    ) {
                        store.toggleSplitAxis()
                    }
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
                .foregroundStyle(theme.label)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
        HStack(spacing: 6) {
            ForEach(store.visiblePanes) { pane in
                paneButton(pane, systemName: symbol(for: pane))
            }
        }
        .padding(8)
        .presentationBackground(theme.background)
    }

    private func symbol(for pane: BrowserPane) -> String {
        switch store.splitLayout {
        case .single:
            return "rectangle"
        case .pair(let axis) where axis == .horizontal:
            return pane == .primary ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled"
        case .pair:
            return pane == .primary ? "rectangle.tophalf.filled" : "rectangle.bottomhalf.filled"
        case .triple, .quad:
            return "square.grid.2x2"
        }
    }

    private func paneButton(_ pane: BrowserPane, systemName: String) -> some View {
        Button {
            store.placeTab(tabID, in: pane)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                Text(store.paneBadge(pane))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .frame(width: 52, height: 46)
            .foregroundStyle(theme.label)
            .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.border, lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show in pane \(pane.gridLabel)")
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
                .onChange(of: focused) { _, isFocused in
                    guard isFocused else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.selectAll(_:)),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                }
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
    @Environment(BrowserTheme.self) private var theme

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
                .foregroundStyle(theme.label)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
    }
}

private struct PaneFocusControl: View {
    let store: WorkspaceBrowserStore

    var body: some View {
        let panes = store.visiblePanes

        Picker("Active pane", selection: Binding(
            get: { store.activePane },
            set: { store.setActivePane($0) }
        )) {
            ForEach(panes) { pane in
                Text(store.paneBadge(pane)).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: CGFloat(panes.count) * 30)
        .accessibilityLabel("Active split pane")
    }
}

private struct AppBarIconButton: View {
    @Environment(BrowserTheme.self) private var theme

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
                .foregroundStyle(selected ? theme.background : theme.label)
                .background(selected ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}
