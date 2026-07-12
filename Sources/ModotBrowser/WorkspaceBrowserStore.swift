import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WorkspaceBrowserStore {
    static let defaultStorageKey = "modot-browser.snapshot.v2"

    var workspaces: [BrowserWorkspace]
    var activeWorkspaceID: UUID
    var groups: [ServiceGroup]
    var bookmarks: [ServiceBookmark]
    var commandBarCollapsed: Bool
    var siteSettings: [SiteSettingsRecord]
    var pageNotes: [PageNoteRecord]
    var autoArchiveAfterDays: Int

    var activePane: BrowserPane = .primary
    var sidebarVisible = false
    var commandPalettePresented = false
    var presentedSheet: BrowserSheetDestination?
    var sharePayload: SharePayload?
    var toastMessage: String?
    var webViewRevision = 0

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
            pageNotes = snapshot.pageNotes
            autoArchiveAfterDays = snapshot.autoArchiveAfterDays
        } else {
            let workspace = BrowserWorkspace.fresh(name: "Main")
            workspaces = [workspace]
            activeWorkspaceID = workspace.id
            groups = [ServiceGroup(id: UUID(), name: "Tailnet")]
            bookmarks = []
            commandBarCollapsed = false
            siteSettings = []
            pageNotes = []
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
            if selectedTabID(for: .primary) == tab.id { return true }
            if activeWorkspace.splitEnabled, selectedTabID(for: .secondary) == tab.id { return true }
            return activeWorkspace.tabs.first(where: { $0.stackID == stackID })?.id == tab.id
        }
    }

    var pinnedBookmarks: [ServiceBookmark] { bookmarks.filter(\.isPinned) }
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

    var currentPageNote: PageNoteRecord? {
        let key = currentPageKey
        return pageNotes.first(where: { $0.workspaceID == activeWorkspaceID && $0.pageKey == key })
    }

    func selectedTabID(for pane: BrowserPane) -> UUID {
        let workspace = activeWorkspace
        return pane == .primary ? workspace.primaryTabID : (workspace.secondaryTabID ?? workspace.primaryTabID)
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
        guard pane == .primary || activeWorkspace.splitEnabled else { return }
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

    func selectTab(_ tabID: UUID, for pane: BrowserPane? = nil) {
        let targetPane = pane ?? activePane
        guard activeWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        updateActiveWorkspace { workspace in
            setSelectedTab(tabID, for: targetPane, in: &workspace)
            if let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) {
                workspace.tabs[index].lastAccessedAt = .now
            }
        }
        activePane = targetPane
        hibernateOverflowSessions()
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
                activePane = .primary
                return
            }
            if let existing = workspace.tabs.first(where: { $0.id != workspace.primaryTabID }) {
                workspace.secondaryTabID = existing.id
            } else {
                let tab = BrowserTabRecord.start()
                workspace.tabs.append(tab)
                workspace.secondaryTabID = tab.id
            }
            workspace.splitEnabled = true
            activePane = .secondary
        }
    }

    func setSplitRatio(_ ratio: Double) {
        updateActiveWorkspace { $0.splitRatio = min(max(ratio, 0.25), 0.75) }
    }

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
        let selected = Set([
            selectedTabID(for: .primary),
            activeWorkspace.splitEnabled ? selectedTabID(for: .secondary) : nil
        ].compactMap { $0 })
        sessions = sessions.filter { selected.contains($0.key) }
        persist()
    }

    func autoArchiveStaleTabs(now: Date = .now) {
        guard autoArchiveAfterDays > 0,
              let threshold = Calendar.current.date(byAdding: .day, value: -autoArchiveAfterDays, to: now) else { return }
        for workspaceIndex in workspaces.indices {
            var workspace = workspaces[workspaceIndex]
            let selected = Set([workspace.primaryTabID, workspace.secondaryTabID].compactMap { $0 })
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

    func saveCurrentPageNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = currentPageKey
        if let index = pageNotes.firstIndex(where: { $0.workspaceID == activeWorkspaceID && $0.pageKey == key }) {
            if trimmed.isEmpty {
                pageNotes.remove(at: index)
            } else {
                pageNotes[index].text = text
                pageNotes[index].pageTitle = currentPageTitle
                pageNotes[index].modifiedAt = .now
            }
        } else if !trimmed.isEmpty {
            pageNotes.append(
                PageNoteRecord(
                    id: UUID(), workspaceID: activeWorkspaceID, pageKey: key,
                    pageTitle: currentPageTitle, text: text, modifiedAt: .now
                )
            )
        }
        persist()
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
        addBookmark(title: title, urlString: url.absoluteString, groupID: groups.first?.id, isPinned: true)
    }

    func addBookmark(title: String, urlString: String, groupID: UUID?, isPinned: Bool) {
        guard let url = BrowserURL.resolve(urlString) else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(
            ServiceBookmark(
                id: UUID(), title: normalizedTitle.isEmpty ? (url.host() ?? "Service") : normalizedTitle,
                urlString: url.absoluteString, groupID: groupID, isPinned: isPinned
            )
        )
        persist()
        refreshServiceStatuses()
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
        pageNotes.removeAll(where: { $0.workspaceID == workspaceID })
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

    private var currentPageKey: String {
        guard let url = currentPageURL else { return "start" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
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
            let otherSelected = pane == .primary ? workspace.secondaryTabID : workspace.primaryTabID
            if otherSelected == tabID {
                let currentSelected = pane == .primary ? workspace.primaryTabID : workspace.secondaryTabID
                if pane == .primary { workspace.secondaryTabID = currentSelected }
                else if let currentSelected { workspace.primaryTabID = currentSelected }
            }
        }
        if pane == .primary { workspace.primaryTabID = tabID }
        else { workspace.secondaryTabID = tabID }
    }

    private func removeTab(
        _ tabID: UUID,
        replacementIfNeeded: Bool,
        beforeRemoval: (inout BrowserWorkspace) -> Void
    ) {
        updateActiveWorkspace { workspace in
            beforeRemoval(&workspace)
            workspace.tabs.removeAll(where: { $0.id == tabID })
            if workspace.tabs.isEmpty, replacementIfNeeded {
                workspace.tabs.append(.start())
            }
            let fallback = workspace.tabs.first?.id
            if workspace.primaryTabID == tabID, let fallback { workspace.primaryTabID = fallback }
            if workspace.secondaryTabID == tabID {
                workspace.secondaryTabID = workspace.tabs.first(where: { $0.id != workspace.primaryTabID })?.id
                    ?? workspace.primaryTabID
            }
        }
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
        let protected = Set([selectedTabID(for: .primary), activeWorkspace.splitEnabled ? selectedTabID(for: .secondary) : nil].compactMap { $0 })
        let candidates = sessions.keys.filter { !protected.contains($0) }.sorted { lhs, rhs in
            let left = workspaces.flatMap(\.tabs).first(where: { $0.id == lhs })?.lastAccessedAt ?? .distantPast
            let right = workspaces.flatMap(\.tabs).first(where: { $0.id == rhs })?.lastAccessedAt ?? .distantPast
            return left < right
        }
        for id in candidates.prefix(max(sessions.count - 6, 0)) { sessions.removeValue(forKey: id) }
    }

    private func recreateVisibleSessions() {
        syncAllSessionsIntoModel()
        sessions.removeValue(forKey: selectedTabID(for: .primary))
        if activeWorkspace.splitEnabled {
            sessions.removeValue(forKey: selectedTabID(for: .secondary))
        }
        webViewRevision += 1
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
            if !workspaces[index].tabs.contains(where: { $0.id == workspaces[index].primaryTabID }) {
                workspaces[index].primaryTabID = workspaces[index].tabs[0].id
            }
            if let secondaryID = workspaces[index].secondaryTabID,
               !workspaces[index].tabs.contains(where: { $0.id == secondaryID }) {
                workspaces[index].secondaryTabID = nil
                workspaces[index].splitEnabled = false
            }
            let stackIDs = Set(workspaces[index].tabStacks.map(\.id))
            for tabIndex in workspaces[index].tabs.indices
            where workspaces[index].tabs[tabIndex].stackID.map({ !stackIDs.contains($0) }) ?? false {
                workspaces[index].tabs[tabIndex].stackID = nil
            }
            workspaces[index].splitRatio = min(max(workspaces[index].splitRatio, 0.25), 0.75)
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
            pageNotes: pageNotes,
            autoArchiveAfterDays: autoArchiveAfterDays
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
