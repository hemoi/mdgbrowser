import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WorkspaceBrowserStore {
    static let defaultStorageKey = "reto-browser.snapshot.v2"

    var workspaces: [BrowserWorkspace]
    var activeWorkspaceID: UUID
    var groups: [ServiceGroup]
    var bookmarks: [ServiceBookmark]
    var commandBarCollapsed: Bool
    var siteSettings: [SiteSettingsRecord]
    var autoArchiveAfterDays: Int

    var activePane: BrowserPane = .primary
    /// Mirrors the horizontal size class. Compact widths (phones) always
    /// stack panes top/bottom and cap the layout at two panes, following
    /// platform conventions; regular widths (iPad) default to left/right
    /// and can grow to a 2×2 grid.
    var layoutIsCompact = false
    var sidebarVisible = false
    var commandPalettePresented = false
    var presentedSheet: BrowserSheetDestination?
    var sharePayload: SharePayload?
    var toastMessage: String?
    var webViewRevision = 0
    var tabDragState: TabDragState?
    var panePlacementPromptTabID: UUID?

    @ObservationIgnored let statusMonitor: ServiceStatusMonitor
    @ObservationIgnored let downloadManager: BrowserDownloadManager
    @ObservationIgnored let contentBlocker: BrowserContentBlocker

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var sessions: [UUID: BrowserSession] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = WorkspaceBrowserStore.defaultStorageKey,
        statusMonitor: ServiceStatusMonitor? = nil,
        downloadManager: BrowserDownloadManager? = nil,
        contentBlocker: BrowserContentBlocker? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.statusMonitor = statusMonitor ?? ServiceStatusMonitor()
        self.downloadManager = downloadManager ?? BrowserDownloadManager()
        self.contentBlocker = contentBlocker ?? BrowserContentBlocker()

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(BrowserSnapshot.self, from: data),
           !snapshot.workspaces.isEmpty {
            workspaces = snapshot.workspaces
            activeWorkspaceID = snapshot.activeWorkspaceID
            groups = snapshot.groups
            bookmarks = snapshot.bookmarks
            commandBarCollapsed = snapshot.commandBarCollapsed
            siteSettings = snapshot.siteSettings
            autoArchiveAfterDays = snapshot.autoArchiveAfterDays
        } else {
            let workspace = BrowserWorkspace.fresh(name: "Main")
            workspaces = [workspace]
            activeWorkspaceID = workspace.id
            groups = [ServiceGroup(id: UUID(), name: "Tailnet")]
            bookmarks = []
            commandBarCollapsed = false
            siteSettings = []
            autoArchiveAfterDays = 14
        }

        normalizeState()
        autoArchiveStaleTabs(now: .now)
    }

    var activeWorkspace: BrowserWorkspace { workspaces[activeWorkspaceIndex] }

    var orderedTabs: [BrowserTabRecord] {
        activeWorkspace.tabs.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return activeWorkspace.tabs.firstIndex(of: $0) ?? 0 < activeWorkspace.tabs.firstIndex(of: $1) ?? 0
        }
    }

    var visibleOrderedTabs: [BrowserTabRecord] {
        orderedTabs.filter { tab in
            guard let stackID = tab.stackID,
                  let stack = activeWorkspace.tabStacks.first(where: { $0.id == stackID }),
                  stack.isCollapsed else { return true }
            if paneShowing(tab.id) != nil { return true }
            return activeWorkspace.tabs.first(where: { $0.stackID == stackID })?.id == tab.id
        }
    }

    /// Panes the canvas actually renders. Compact widths clip the grid down
    /// to the first two slots; the hidden tabs stay reachable from the strip.
    var visiblePanes: [BrowserPane] {
        let occupied = activeWorkspace.occupiedPanes
        return layoutIsCompact ? Array(occupied.prefix(2)) : occupied
    }

    var effectiveSplitAxis: BrowserSplitAxis {
        layoutIsCompact ? .vertical : activeWorkspace.splitAxis
    }

    var splitLayout: BrowserSplitLayout {
        switch visiblePanes.count {
        case ...1: .single
        case 2: .pair(effectiveSplitAxis)
        case 3: .triple
        default: .quad
        }
    }

    var canAddPane: Bool {
        layoutIsCompact
            ? !activeWorkspace.splitEnabled
            : activeWorkspace.occupiedPanes.count < BrowserPane.slotOrder.count
    }

    func paneBadge(_ pane: BrowserPane) -> String {
        switch splitLayout {
        case .single, .pair: effectiveSplitAxis.badge(for: pane)
        case .triple, .quad: pane.gridLabel
        }
    }

    var visibleBookmarks: [ServiceBookmark] { bookmarks.filter { $0.isVisible(in: activeWorkspaceID) } }
    var pinnedBookmarks: [ServiceBookmark] { visibleBookmarks.filter(\.isPinned) }
    var canDeleteActiveWorkspace: Bool { workspaces.count > 1 }
    var recentlyClosedTabs: [StoredTabRecord] { activeWorkspace.recentlyClosedTabs }
    var archivedTabs: [StoredTabRecord] { activeWorkspace.archivedTabs }
    var activeTabIsHibernated: Bool { sessions[selectedTabID(for: activePane)] == nil }

    func isTabHibernated(_ tabID: UUID) -> Bool { sessions[tabID] == nil }

    var currentPageURL: URL? {
        let tab = selectedTab(for: activePane)
        return sessions[tab.id]?.currentURL ?? BrowserURL.resolve(tab.urlString)
    }

    var currentPageTitle: String {
        let tab = selectedTab(for: activePane)
        let liveTitle = sessions[tab.id]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return liveTitle.isEmpty ? tab.title : liveTitle
    }

    func selectedTabID(for pane: BrowserPane) -> UUID {
        activeWorkspace.tabID(for: pane) ?? activeWorkspace.primaryTabID
    }

    func selectedTab(for pane: BrowserPane) -> BrowserTabRecord {
        let tabID = selectedTabID(for: pane)
        return activeWorkspace.tabs.first(where: { $0.id == tabID }) ?? activeWorkspace.tabs[0]
    }

    func session(for pane: BrowserPane) -> BrowserSession { session(for: selectedTab(for: pane)) }

    func session(for record: BrowserTabRecord) -> BrowserSession {
        if let session = sessions[record.id] { return session }
        let workspaceID = workspaceID(containing: record.id) ?? activeWorkspaceID
        let session = makeSession(
            workspaceID: workspaceID,
            record: record
        )
        sessions[record.id] = session
        return session
    }

    func prepareWebFeatures() async {
        await contentBlocker.prepare()
        for session in sessions.values { session.applyCurrentSiteSettings(reload: false) }
        refreshServiceStatuses()
    }

    func setActivePane(_ pane: BrowserPane) {
        guard pane == .primary || visiblePanes.contains(pane) else { return }
        activePane = pane
        touchTab(selectedTabID(for: pane))
    }

    @discardableResult
    func addTab(in pane: BrowserPane? = nil, opening url: URL? = nil) -> UUID {
        let targetPane = pane ?? activePane
        var tab = BrowserTabRecord.start()
        if let url {
            tab.title = url.host() ?? url.absoluteString
            tab.urlString = url.absoluteString
        }
        updateActiveWorkspace { workspace in
            workspace.tabs.append(tab)
            setSelectedTab(tab.id, for: targetPane, in: &workspace)
        }
        activePane = targetPane
        if let url { session(for: tab).open(url) }
        return tab.id
    }

    func closeTab(_ tabID: UUID) {
        guard let tab = activeWorkspace.tabs.first(where: { $0.id == tabID }) else { return }
        syncSessionIntoModel(tabID)
        removeTab(tabID, replacementIfNeeded: true) { workspace in
            workspace.recentlyClosedTabs.insert(StoredTabRecord(tab: tab), at: 0)
            workspace.recentlyClosedTabs = Array(workspace.recentlyClosedTabs.prefix(20))
        }
    }

    func reopenLastClosedTab() {
        guard let stored = activeWorkspace.recentlyClosedTabs.first else { return }
        restoreClosedTab(stored.id)
    }

    func restoreClosedTab(_ storedID: UUID) {
        guard let stored = activeWorkspace.recentlyClosedTabs.first(where: { $0.id == storedID }) else { return }
        updateActiveWorkspace { workspace in
            workspace.recentlyClosedTabs.removeAll(where: { $0.id == storedID })
            var tab = stored.tab
            tab.lastAccessedAt = .now
            if workspace.tabs.contains(where: { $0.id == tab.id }) {
                tab = BrowserTabRecord(
                    id: UUID(), title: tab.title, urlString: tab.urlString,
                    isPinned: tab.isPinned, groupID: tab.groupID, stackID: tab.stackID
                )
            }
            workspace.tabs.append(tab)
            setSelectedTab(tab.id, for: activePane, in: &workspace)
        }
    }

    func archiveTab(_ tabID: UUID) {
        guard let tab = activeWorkspace.tabs.first(where: { $0.id == tabID }) else { return }
        syncSessionIntoModel(tabID)
        removeTab(tabID, replacementIfNeeded: true) { workspace in
            workspace.archivedTabs.insert(StoredTabRecord(tab: tab), at: 0)
        }
    }

    func restoreArchivedTab(_ storedID: UUID) {
        guard let stored = activeWorkspace.archivedTabs.first(where: { $0.id == storedID }) else { return }
        updateActiveWorkspace { workspace in
            workspace.archivedTabs.removeAll(where: { $0.id == storedID })
            var tab = stored.tab
            tab.lastAccessedAt = .now
            if workspace.tabs.contains(where: { $0.id == tab.id }) {
                tab = BrowserTabRecord(
                    id: UUID(), title: tab.title, urlString: tab.urlString,
                    isPinned: tab.isPinned, groupID: tab.groupID, stackID: tab.stackID
                )
            }
            workspace.tabs.append(tab)
            setSelectedTab(tab.id, for: activePane, in: &workspace)
        }
    }

    func deleteArchivedTab(_ storedID: UUID) {
        updateActiveWorkspace { $0.archivedTabs.removeAll(where: { $0.id == storedID }) }
    }

    /// The pane currently displaying the tab, if any.
    func paneShowing(_ tabID: UUID) -> BrowserPane? {
        if activeWorkspace.primaryTabID == tabID { return .primary }
        guard activeWorkspace.splitEnabled else { return nil }
        return visiblePanes.first(where: { activeWorkspace.tabID(for: $0) == tabID })
    }

    func selectTab(_ tabID: UUID, for pane: BrowserPane? = nil) {
        guard activeWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        let targetPane = pane ?? implicitTargetPane(for: tabID)
        updateActiveWorkspace { workspace in
            setSelectedTab(tabID, for: targetPane, in: &workspace)
            if let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) {
                workspace.tabs[index].lastAccessedAt = .now
            }
        }
        activePane = targetPane
        hibernateOverflowSessions()
    }

    /// Tab strip tap behavior. In split view a visible tab focuses its pane, a
    /// tab with a remembered side returns to that side, and an unplaced tab
    /// asks where it should go via the L/R chooser.
    func handleTabTap(_ tabID: UUID) {
        guard activeWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        guard activeWorkspace.splitEnabled else {
            panePlacementPromptTabID = nil
            selectTab(tabID)
            return
        }
        if let visiblePane = paneShowing(tabID) {
            panePlacementPromptTabID = nil
            setActivePane(visiblePane)
        } else if let preferred = tabRecord(tabID)?.preferredPane {
            panePlacementPromptTabID = nil
            selectTab(tabID, for: preferred)
        } else {
            panePlacementPromptTabID = panePlacementPromptTabID == tabID ? nil : tabID
        }
    }

    /// Places a tab into a specific pane, enabling split view when needed.
    /// Dropping on the left/top edge keeps the current page on the other
    /// side, and vice versa. Passing an axis switches between the
    /// side-by-side and stacked layouts.
    func placeTab(_ tabID: UUID, in pane: BrowserPane, axis: BrowserSplitAxis? = nil) {
        guard activeWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        panePlacementPromptTabID = nil
        updateActiveWorkspace { workspace in
            // Compact widths only stack panes; an edge drop still works but
            // always lands in the vertical arrangement.
            if let axis { workspace.splitAxis = layoutIsCompact ? .vertical : axis }
            if workspace.splitEnabled {
                setSelectedTab(tabID, for: pane, in: &workspace)
            } else {
                let currentTabID = workspace.primaryTabID
                var companionID = currentTabID
                if currentTabID == tabID {
                    if let other = workspace.tabs.first(where: { $0.id != tabID }) {
                        companionID = other.id
                    } else {
                        let tab = BrowserTabRecord.start()
                        workspace.tabs.append(tab)
                        companionID = tab.id
                    }
                }
                workspace.primaryTabID = pane == .primary ? tabID : companionID
                workspace.secondaryTabID = pane == .primary ? companionID : tabID
                workspace.splitEnabled = true
            }
            rememberPanePlacements(in: &workspace)
            if let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) {
                workspace.tabs[index].lastAccessedAt = .now
            }
        }
        activePane = paneShowing(tabID) ?? pane
        hibernateOverflowSessions()
    }

    func beginTabDrag(_ tabID: UUID, at location: CGPoint? = nil) {
        guard activeWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        panePlacementPromptTabID = nil
        tabDragState = TabDragState(tabID: tabID, location: location, target: nil)
        TabDragHaptics.dragBegan()
    }

    func updateTabDrag(location: CGPoint) {
        tabDragState?.location = location
    }

    func updateTabDragTarget(_ target: TabDragTarget?) {
        guard tabDragState != nil, tabDragState?.target != target else { return }
        tabDragState?.target = target
        if target != nil { TabDragHaptics.targetChanged() }
    }

    func finishTabDrag() {
        guard let state = tabDragState else { return }
        tabDragState = nil
        switch state.target {
        case .tab(let hoveredID):
            selectTab(hoveredID)
        case .split(let placement):
            placeTab(state.tabID, in: placement.pane, axis: placement.axis)
        case nil:
            break
        }
    }

    func cancelTabDrag() {
        tabDragState = nil
    }

    func toggleTabPin(_ tabID: UUID) {
        updateActiveWorkspace { workspace in
            guard let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            workspace.tabs[index].isPinned.toggle()
        }
    }

    func assignTab(_ tabID: UUID, to groupID: UUID?) {
        updateActiveWorkspace { workspace in
            guard let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            workspace.tabs[index].groupID = groupID
        }
    }

    func createTabStack(name: String, including tabID: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stack = BrowserTabStack(id: UUID(), name: trimmed, isCollapsed: false)
        let targetID = tabID ?? selectedTabID(for: activePane)
        updateActiveWorkspace { workspace in
            workspace.tabStacks.append(stack)
            if let index = workspace.tabs.firstIndex(where: { $0.id == targetID }) {
                workspace.tabs[index].stackID = stack.id
            }
        }
    }

    func assignTab(_ tabID: UUID, toStack stackID: UUID?) {
        updateActiveWorkspace { workspace in
            guard let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            workspace.tabs[index].stackID = stackID
        }
    }

    func toggleTabStack(_ stackID: UUID) {
        updateActiveWorkspace { workspace in
            guard let index = workspace.tabStacks.firstIndex(where: { $0.id == stackID }) else { return }
            workspace.tabStacks[index].isCollapsed.toggle()
        }
    }

    func deleteTabStack(_ stackID: UUID) {
        updateActiveWorkspace { workspace in
            workspace.tabStacks.removeAll(where: { $0.id == stackID })
            for index in workspace.tabs.indices where workspace.tabs[index].stackID == stackID {
                workspace.tabs[index].stackID = nil
            }
        }
    }

    func toggleSplit() {
        updateActiveWorkspace { workspace in
            if workspace.splitEnabled {
                workspace.splitEnabled = false
                workspace.tertiaryTabID = nil
                workspace.quaternaryTabID = nil
                activePane = .primary
                return
            }
            let candidates = workspace.tabs.filter { $0.id != workspace.primaryTabID }
            if let existing = candidates.first(where: { $0.preferredPane == .secondary }) ?? candidates.first {
                workspace.secondaryTabID = existing.id
            } else {
                let tab = BrowserTabRecord.start()
                workspace.tabs.append(tab)
                workspace.secondaryTabID = tab.id
            }
            workspace.splitEnabled = true
            rememberPanePlacements(in: &workspace)
            activePane = .secondary
        }
    }

    /// Fills the next free grid slot with a not-currently-visible tab (or a
    /// fresh start tab). On compact widths this can only create the first
    /// split, since the layout caps at two stacked panes.
    func addPane() {
        guard canAddPane else { return }
        guard activeWorkspace.splitEnabled else {
            toggleSplit()
            return
        }
        updateActiveWorkspace { workspace in
            guard let target = BrowserPane.slotOrder.first(where: { workspace.tabID(for: $0) == nil }) else { return }
            let visibleIDs = Set(BrowserPane.slotOrder.compactMap { workspace.tabID(for: $0) })
            let candidates = workspace.tabs.filter { !visibleIDs.contains($0.id) }
            let tabID: UUID
            if let existing = candidates.first(where: { $0.preferredPane == target }) ?? candidates.first {
                tabID = existing.id
            } else {
                let tab = BrowserTabRecord.start()
                workspace.tabs.append(tab)
                tabID = tab.id
            }
            workspace.setTabID(tabID, for: target)
            rememberPanePlacements(in: &workspace)
            activePane = target
        }
        hibernateOverflowSessions()
    }

    /// Removes one pane from the layout (the tab itself stays open). Slots
    /// compact down so occupancy stays contiguous.
    func closePane(_ pane: BrowserPane) {
        guard activeWorkspace.splitEnabled else { return }
        updateActiveWorkspace { workspace in
            if pane == .primary {
                if let next = workspace.secondaryTabID {
                    workspace.primaryTabID = next
                    workspace.secondaryTabID = nil
                }
            } else {
                workspace.setTabID(nil, for: pane)
            }
            normalizePanes(in: &workspace)
            rememberPanePlacements(in: &workspace)
        }
        activePane = .primary
    }

    func toggleSplitAxis() {
        guard !layoutIsCompact else { return }
        updateActiveWorkspace { workspace in
            workspace.splitAxis = workspace.splitAxis == .horizontal ? .vertical : .horizontal
        }
    }

    func setSplitRatio(_ ratio: Double, persistImmediately: Bool = true) {
        let clamped = min(max(ratio, 0.25), 0.75)
        let index = activeWorkspaceIndex
        guard workspaces[index].splitRatio != clamped else { return }
        workspaces[index].splitRatio = clamped
        if persistImmediately { persist() }
    }

    func setSplitRowRatio(_ ratio: Double, persistImmediately: Bool = true) {
        let clamped = min(max(ratio, 0.25), 0.75)
        let index = activeWorkspaceIndex
        guard workspaces[index].splitRowRatio != clamped else { return }
        workspaces[index].splitRowRatio = clamped
        if persistImmediately { persist() }
    }

    func persistSplitRatio() { persist() }

    func open(_ url: URL, in pane: BrowserPane? = nil) {
        let targetPane = pane ?? activePane
        let tab = selectedTab(for: targetPane)
        session(for: tab).open(url)
        updateTab(tab.id, url: url, title: url.host() ?? url.absoluteString)
    }

    func submitAddress(in pane: BrowserPane? = nil) {
        let targetPane = pane ?? activePane
        let tab = selectedTab(for: targetPane)
        let session = session(for: tab)
        guard let url = session.openAddress() else { return }
        updateTab(tab.id, url: url, title: url.host() ?? url.absoluteString)
    }

    func syncTabFromSession(_ tabID: UUID) {
        guard let session = sessions[tabID], let url = session.currentURL else { return }
        let pageTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTab(tabID, url: url, title: pageTitle.isEmpty ? (url.host() ?? url.absoluteString) : pageTitle)
    }

    func hibernateInactiveTabs() {
        syncAllSessionsIntoModel()
        let selected = paneTabIDs(of: activeWorkspace)
        sessions = sessions.filter { selected.contains($0.key) }
        persist()
    }

    /// Tabs occupying any pane slot of the workspace, hidden compact slots
    /// included, so a rotation or window resize never lands on a torn-down
    /// session.
    private func paneTabIDs(of workspace: BrowserWorkspace) -> Set<UUID> {
        var ids: Set<UUID> = [workspace.primaryTabID]
        if workspace.splitEnabled {
            for pane in BrowserPane.slotOrder {
                if let id = workspace.tabID(for: pane) { ids.insert(id) }
            }
        }
        return ids
    }

    func autoArchiveStaleTabs(now: Date = .now) {
        guard autoArchiveAfterDays > 0,
              let threshold = Calendar.current.date(byAdding: .day, value: -autoArchiveAfterDays, to: now) else { return }
        for workspaceIndex in workspaces.indices {
            var workspace = workspaces[workspaceIndex]
            let selected = paneTabIDs(of: workspace)
            let stale = workspace.tabs.filter {
                !$0.isPinned && !selected.contains($0.id) && $0.lastAccessedAt < threshold
            }
            guard !stale.isEmpty else { continue }
            workspace.tabs.removeAll(where: { tab in stale.contains(where: { $0.id == tab.id }) })
            workspace.archivedTabs.insert(contentsOf: stale.map { StoredTabRecord(tab: $0, storedAt: now) }, at: 0)
            workspaces[workspaceIndex] = workspace
            stale.forEach { sessions.removeValue(forKey: $0.id) }
        }
        persist()
    }

    func settings(for url: URL?, workspaceID: UUID? = nil) -> SiteSettingsRecord {
        let ownerID = workspaceID ?? activeWorkspaceID
        let host = url?.host()?.lowercased() ?? ""
        return siteSettings.first(where: { $0.workspaceID == ownerID && $0.host.lowercased() == host })
            ?? SiteSettingsRecord(workspaceID: ownerID, host: host)
    }

    func saveSiteSettings(_ settings: SiteSettingsRecord) {
        if let index = siteSettings.firstIndex(where: { $0.id == settings.id }) {
            siteSettings[index] = settings
        } else {
            siteSettings.append(settings)
        }
        persist()
        recreateVisibleSessions()
    }

    func clearCurrentSiteData() {
        guard let host = currentPageURL?.host()?.lowercased() else { return }
        let dataStore = WKWebsiteDataStore(forIdentifier: activeWorkspaceID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { [weak self] records in
            let matching = records.filter {
                let name = $0.displayName.lowercased()
                return name == host || host.hasSuffix(".\(name)") || name.hasSuffix(".\(host)")
            }
            dataStore.removeData(ofTypes: types, for: matching) {
                self?.toastMessage = "Cleared data for \(host)"
                self?.session(for: self?.activePane ?? .primary).reloadWithoutCache()
            }
        }
    }

    func clearActiveWorkspaceData() {
        hibernateInactiveTabs()
        sessions.removeAll()
        webViewRevision += 1
        let store = WKWebsiteDataStore(forIdentifier: activeWorkspaceID)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.toastMessage = "Workspace website data cleared"
        }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains(where: { $0.url?.absoluteString == url.absoluteString })
    }

    func quickToggleBookmark(for pane: BrowserPane? = nil) {
        let targetPane = pane ?? activePane
        let tab = selectedTab(for: targetPane)
        let session = session(for: tab)
        guard let url = session.currentURL else { return }
        if let existing = bookmarks.first(where: { $0.url?.absoluteString == url.absoluteString }) {
            removeBookmark(existing.id)
            return
        }
        let title = session.title.isEmpty ? (url.host() ?? "Service") : session.title
        addBookmark(
            title: title, urlString: url.absoluteString, groupID: groups.first?.id,
            isPinned: true, workspaceID: activeWorkspaceID
        )
        toastMessage = "Bookmarked in \(activeWorkspace.name)"
    }

    func addBookmark(title: String, urlString: String, groupID: UUID?, isPinned: Bool, workspaceID: UUID? = nil) {
        guard let url = BrowserURL.resolve(urlString) else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(
            ServiceBookmark(
                id: UUID(), title: normalizedTitle.isEmpty ? (url.host() ?? "Service") : normalizedTitle,
                urlString: url.absoluteString, groupID: groupID, isPinned: isPinned,
                workspaceID: workspaceID
            )
        )
        persist()
        refreshServiceStatuses()
    }

    func assignBookmark(_ bookmarkID: UUID, toWorkspace workspaceID: UUID?) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        bookmarks[index].workspaceID = workspaceID
        persist()
    }

    func removeBookmark(_ bookmarkID: UUID) {
        bookmarks.removeAll(where: { $0.id == bookmarkID })
        persist()
    }

    func toggleBookmarkPin(_ bookmarkID: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        bookmarks[index].isPinned.toggle()
        persist()
    }

    func toggleBookmarkMonitoring(_ bookmarkID: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        bookmarks[index].monitorsStatus.toggle()
        persist()
        refreshServiceStatuses()
    }

    func assignBookmark(_ bookmarkID: UUID, to groupID: UUID?) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        bookmarks[index].groupID = groupID
        persist()
    }

    func openBookmark(_ bookmarkID: UUID) {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }), let url = bookmark.url else { return }
        open(url)
        sidebarVisible = false
    }

    func refreshServiceStatuses() { statusMonitor.refresh(bookmarks) }

    func addGroup(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups.append(ServiceGroup(id: UUID(), name: trimmed))
        persist()
    }

    func deleteGroup(_ groupID: UUID) {
        groups.removeAll(where: { $0.id == groupID })
        for index in bookmarks.indices where bookmarks[index].groupID == groupID { bookmarks[index].groupID = nil }
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices
            where workspaces[workspaceIndex].tabs[tabIndex].groupID == groupID {
                workspaces[workspaceIndex].tabs[tabIndex].groupID = nil
            }
        }
        persist()
    }

    func addWorkspace(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        syncAllSessionsIntoModel()
        let workspace = BrowserWorkspace.fresh(name: trimmed)
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        activePane = .primary
        sidebarVisible = false
        sessions.removeAll()
        persist()
    }

    func selectWorkspace(_ workspaceID: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceID }), workspaceID != activeWorkspaceID else { return }
        syncAllSessionsIntoModel()
        activeWorkspaceID = workspaceID
        activePane = .primary
        panePlacementPromptTabID = nil
        tabDragState = nil
        sessions.removeAll()
        persist()
    }

    func deleteWorkspace(_ workspaceID: UUID) {
        guard workspaces.count > 1,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let removedTabIDs = workspaces[index].tabs.map(\.id)
        workspaces.remove(at: index)
        removedTabIDs.forEach { sessions.removeValue(forKey: $0) }
        siteSettings.removeAll(where: { $0.workspaceID == workspaceID })
        bookmarks.removeAll(where: { $0.workspaceID == workspaceID })
        if activeWorkspaceID == workspaceID {
            activeWorkspaceID = workspaces[0].id
            activePane = .primary
        }
        persist()
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: workspaceID) }
    }

    func shareCurrentPage() {
        guard let url = currentPageURL else { return }
        sharePayload = SharePayload(url: url)
    }

    func registerGeneratedDownload(_ url: URL) {
        downloadManager.addGeneratedFile(url, sourceURL: currentPageURL)
        sharePayload = SharePayload(url: url)
    }

    func toggleCommandBar() {
        commandBarCollapsed.toggle()
        persist()
    }

    func resetForTesting() { defaults.removeObject(forKey: storageKey) }

    private var activeWorkspaceIndex: Int {
        workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) ?? 0
    }

    private func workspaceID(containing tabID: UUID) -> UUID? {
        workspaces.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })?.id
    }

    private func makeSession(
        workspaceID: UUID,
        record: BrowserTabRecord,
        configuration: WKWebViewConfiguration? = nil,
        startsLoaded: Bool = false
    ) -> BrowserSession {
        BrowserSession(
            workspaceID: workspaceID,
            record: record,
            contentBlocker: contentBlocker,
            downloadManager: downloadManager,
            settingsProvider: { [weak self] url in
                self?.settings(for: url, workspaceID: workspaceID)
                    ?? SiteSettingsRecord(workspaceID: workspaceID, host: url?.host() ?? "")
            },
            webViewConfiguration: configuration,
            startsLoaded: startsLoaded,
            newWindowHandler: { [weak self] url, popupConfiguration in
                self?.createPopupWebView(opening: url, configuration: popupConfiguration)
            },
            closeHandler: { [weak self] in
                self?.closeTab(record.id)
            }
        )
    }

    private func createPopupWebView(
        opening url: URL?,
        configuration: WKWebViewConfiguration
    ) -> WKWebView? {
        let targetPane = activePane
        var tab = BrowserTabRecord.start()
        if let url {
            tab.title = url.host() ?? url.absoluteString
            tab.urlString = url.absoluteString
        }
        updateActiveWorkspace { workspace in
            workspace.tabs.append(tab)
            setSelectedTab(tab.id, for: targetPane, in: &workspace)
        }
        let session = makeSession(
            workspaceID: activeWorkspaceID,
            record: tab,
            configuration: configuration,
            startsLoaded: true
        )
        sessions[tab.id] = session
        return session.webView
    }

    private func touchTab(_ tabID: UUID) {
        updateActiveWorkspace { workspace in
            if let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) {
                workspace.tabs[index].lastAccessedAt = .now
            }
        }
    }

    private func updateTab(_ tabID: UUID, url: URL, title: String) {
        updateActiveWorkspace { workspace in
            guard let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            workspace.tabs[index].urlString = url.absoluteString
            workspace.tabs[index].title = title
            workspace.tabs[index].lastAccessedAt = .now
        }
    }

    private func updateActiveWorkspace(_ mutation: (inout BrowserWorkspace) -> Void) {
        let index = activeWorkspaceIndex
        mutation(&workspaces[index])
        persist()
    }

    private func setSelectedTab(_ tabID: UUID, for pane: BrowserPane, in workspace: inout BrowserWorkspace) {
        if workspace.splitEnabled {
            // If the tab is already visible in another pane, swap the two
            // panes' tabs — the same WKWebView must never mount twice.
            for other in BrowserPane.slotOrder where other != pane && workspace.tabID(for: other) == tabID {
                workspace.setTabID(workspace.tabID(for: pane), for: other)
            }
        }
        workspace.setTabID(tabID, for: pane)
        if workspace.splitEnabled {
            normalizePanes(in: &workspace)
            rememberPanePlacements(in: &workspace)
        }
    }

    /// Records which slot each visible tab occupies so a tab that was once on
    /// the left keeps returning to the left.
    private func rememberPanePlacements(in workspace: inout BrowserWorkspace) {
        for pane in workspace.occupiedPanes {
            if let tabID = workspace.tabID(for: pane),
               let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) {
                workspace.tabs[index].preferredPane = pane
            }
        }
    }

    private func tabRecord(_ tabID: UUID) -> BrowserTabRecord? {
        activeWorkspace.tabs.first(where: { $0.id == tabID })
    }

    /// Where a selection without an explicit pane should land: the remembered
    /// side in split view, otherwise the focused pane.
    private func implicitTargetPane(for tabID: UUID) -> BrowserPane {
        guard activeWorkspace.splitEnabled else { return .primary }
        if let visiblePane = paneShowing(tabID) { return visiblePane }
        if let preferred = tabRecord(tabID)?.preferredPane { return preferred }
        return activePane
    }

    private func removeTab(
        _ tabID: UUID,
        replacementIfNeeded: Bool,
        beforeRemoval: (inout BrowserWorkspace) -> Void
    ) {
        if panePlacementPromptTabID == tabID { panePlacementPromptTabID = nil }
        if tabDragState?.tabID == tabID { tabDragState = nil }
        updateActiveWorkspace { workspace in
            beforeRemoval(&workspace)
            workspace.tabs.removeAll(where: { $0.id == tabID })
            if workspace.tabs.isEmpty, replacementIfNeeded {
                workspace.tabs.append(.start())
            }
            let fallback = workspace.tabs.first?.id
            if workspace.primaryTabID == tabID, let fallback { workspace.primaryTabID = fallback }
            if workspace.secondaryTabID == tabID {
                let occupied = paneTabIDs(of: workspace)
                workspace.secondaryTabID = workspace.tabs.first(where: {
                    $0.id != workspace.primaryTabID && !occupied.contains($0.id)
                })?.id
            }
            if workspace.tertiaryTabID == tabID { workspace.tertiaryTabID = nil }
            if workspace.quaternaryTabID == tabID { workspace.quaternaryTabID = nil }
            normalizePanes(in: &workspace)
        }
        if !visiblePanes.contains(activePane) { activePane = .primary }
        sessions.removeValue(forKey: tabID)
    }

    private func syncSessionIntoModel(_ tabID: UUID) {
        guard let session = sessions[tabID], let url = session.currentURL else { return }
        for workspaceIndex in workspaces.indices {
            guard let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID }) else { continue }
            workspaces[workspaceIndex].tabs[tabIndex].urlString = url.absoluteString
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            workspaces[workspaceIndex].tabs[tabIndex].title = title.isEmpty ? (url.host() ?? url.absoluteString) : title
            return
        }
    }

    private func syncAllSessionsIntoModel() {
        for tabID in sessions.keys { syncSessionIntoModel(tabID) }
    }

    private func hibernateOverflowSessions() {
        guard sessions.count > 6 else { return }
        syncAllSessionsIntoModel()
        let protected = paneTabIDs(of: activeWorkspace)
        let candidates = sessions.keys.filter { !protected.contains($0) }.sorted { lhs, rhs in
            let left = workspaces.flatMap(\.tabs).first(where: { $0.id == lhs })?.lastAccessedAt ?? .distantPast
            let right = workspaces.flatMap(\.tabs).first(where: { $0.id == rhs })?.lastAccessedAt ?? .distantPast
            return left < right
        }
        for id in candidates.prefix(max(sessions.count - 6, 0)) { sessions.removeValue(forKey: id) }
    }

    private func recreateVisibleSessions() {
        syncAllSessionsIntoModel()
        for tabID in paneTabIDs(of: activeWorkspace) {
            sessions.removeValue(forKey: tabID)
        }
        webViewRevision += 1
    }

    /// Restores the pane invariants after any slot mutation: every slot
    /// points at a live tab, no tab occupies two slots (one WKWebView must
    /// never mount twice), occupancy is contiguous, and a split without a
    /// second pane collapses back to a single pane.
    private func normalizePanes(in workspace: inout BrowserWorkspace) {
        let validIDs = Set(workspace.tabs.map(\.id))
        if !validIDs.contains(workspace.primaryTabID), let first = workspace.tabs.first {
            workspace.primaryTabID = first.id
        }
        var seen: Set<UUID> = [workspace.primaryTabID]
        for pane in BrowserPane.slotOrder.dropFirst() {
            guard let id = workspace.tabID(for: pane) else { continue }
            if !validIDs.contains(id) || seen.contains(id) {
                workspace.setTabID(nil, for: pane)
            } else {
                seen.insert(id)
            }
        }
        let extras = [workspace.secondaryTabID, workspace.tertiaryTabID, workspace.quaternaryTabID]
            .compactMap { $0 }
        workspace.secondaryTabID = extras.count > 0 ? extras[0] : nil
        workspace.tertiaryTabID = extras.count > 1 ? extras[1] : nil
        workspace.quaternaryTabID = extras.count > 2 ? extras[2] : nil
        if workspace.splitEnabled, workspace.secondaryTabID == nil {
            workspace.splitEnabled = false
        }
        if !workspace.splitEnabled {
            workspace.tertiaryTabID = nil
            workspace.quaternaryTabID = nil
        }
    }

    private func normalizeState() {
        if !workspaces.contains(where: { $0.id == activeWorkspaceID }) { activeWorkspaceID = workspaces[0].id }
        autoArchiveAfterDays = min(max(autoArchiveAfterDays, 0), 365)
        for index in workspaces.indices {
            if workspaces[index].tabs.isEmpty {
                let tab = BrowserTabRecord.start()
                workspaces[index].tabs = [tab]
                workspaces[index].primaryTabID = tab.id
            }
            normalizePanes(in: &workspaces[index])
            let stackIDs = Set(workspaces[index].tabStacks.map(\.id))
            for tabIndex in workspaces[index].tabs.indices
            where workspaces[index].tabs[tabIndex].stackID.map({ !stackIDs.contains($0) }) ?? false {
                workspaces[index].tabs[tabIndex].stackID = nil
            }
            workspaces[index].splitRatio = min(max(workspaces[index].splitRatio, 0.25), 0.75)
            workspaces[index].splitRowRatio = min(max(workspaces[index].splitRowRatio, 0.25), 0.75)
        }
    }

    private func persist() {
        let snapshot = BrowserSnapshot(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            groups: groups,
            bookmarks: bookmarks,
            commandBarCollapsed: commandBarCollapsed,
            siteSettings: siteSettings,
            autoArchiveAfterDays: autoArchiveAfterDays
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
