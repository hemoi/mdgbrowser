import XCTest
@testable import ModotBrowser

@MainActor
final class WorkspaceBrowserStoreTests: XCTestCase {
    func testSplitCreatesDistinctPaneTabs() {
        let (store, _) = makeStore()

        store.toggleSplit()

        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.activeWorkspace.tabs.count, 2)
        XCTAssertNotEqual(
            store.selectedTabID(for: .primary),
            store.selectedTabID(for: .secondary)
        )
    }

    func testSelectingOtherPaneTabSwapsSelections() {
        let (store, _) = makeStore()
        store.toggleSplit()
        let leftID = store.selectedTabID(for: .primary)
        let rightID = store.selectedTabID(for: .secondary)

        store.selectTab(leftID, for: .secondary)

        XCTAssertEqual(store.selectedTabID(for: .secondary), leftID)
        XCTAssertEqual(store.selectedTabID(for: .primary), rightID)
    }

    func testSplitRatioIsClamped() {
        let (store, _) = makeStore()

        store.setSplitRatio(0.05)
        XCTAssertEqual(store.activeWorkspace.splitRatio, 0.25)

        store.setSplitRatio(0.95)
        XCTAssertEqual(store.activeWorkspace.splitRatio, 0.75)
    }

    func testBookmarkPersistsAcrossStoreInstances() {
        let (store, defaults) = makeStore()
        let key = "test.snapshot"
        let persistentStore = WorkspaceBrowserStore(defaults: defaults, storageKey: key)

        persistentStore.addBookmark(
            title: "Codex",
            urlString: "https://codex.example.ts.net",
            groupID: persistentStore.groups.first?.id,
            isPinned: true
        )

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(restored.bookmarks.count, 1)
        XCTAssertEqual(restored.bookmarks.first?.title, "Codex")
        XCTAssertEqual(restored.pinnedBookmarks.count, 1)

        store.resetForTesting()
        defaults.removeObject(forKey: key)
    }

    func testWorkspaceCreationSelectsNewWorkspace() {
        let (store, _) = makeStore()

        store.addWorkspace(name: "Ops")

        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(store.activeWorkspace.name, "Ops")
        XCTAssertEqual(store.activeWorkspace.tabs.count, 1)
    }

    func testWorkspaceSessionUsesWorkspaceDataStoreIdentifier() {
        let (store, _) = makeStore()
        let session = store.session(for: .primary)

        XCTAssertEqual(session.webView.configuration.websiteDataStore.identifier, store.activeWorkspaceID)

        store.addWorkspace(name: "Private Ops")
        let secondSession = store.session(for: .primary)
        XCTAssertEqual(secondSession.webView.configuration.websiteDataStore.identifier, store.activeWorkspaceID)
        XCTAssertNotEqual(session.workspaceID, secondSession.workspaceID)
    }

    func testClosedTabCanBeRestored() {
        let (store, _) = makeStore()
        let originalID = store.selectedTabID(for: .primary)

        store.closeTab(originalID)

        XCTAssertEqual(store.recentlyClosedTabs.first?.tab.id, originalID)
        XCTAssertNotEqual(store.selectedTabID(for: .primary), originalID)

        store.reopenLastClosedTab()

        XCTAssertEqual(store.selectedTabID(for: .primary), originalID)
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty)
    }

    func testArchivedTabCanBeRestored() {
        let (store, _) = makeStore()
        let originalID = store.selectedTabID(for: .primary)

        store.archiveTab(originalID)
        XCTAssertEqual(store.archivedTabs.first?.tab.id, originalID)

        let storedID = try! XCTUnwrap(store.archivedTabs.first?.id)
        store.restoreArchivedTab(storedID)

        XCTAssertEqual(store.selectedTabID(for: .primary), originalID)
        XCTAssertTrue(store.archivedTabs.isEmpty)
    }

    func testCollapsedStackKeepsOneRepresentativeVisible() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let secondID = store.addTab()
        store.createTabStack(name: "Research", including: firstID)
        let stackID = try! XCTUnwrap(store.activeWorkspace.tabStacks.first?.id)
        store.assignTab(secondID, toStack: stackID)
        store.selectTab(firstID)

        store.toggleTabStack(stackID)

        XCTAssertEqual(store.visibleOrderedTabs.filter { $0.stackID == stackID }.count, 1)
    }

    func testSiteSettingsAndKoreanPageNotePersist() {
        let (store, defaults) = makeStore()
        let key = "feature.snapshot"
        let persistentStore = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        persistentStore.open(URL(string: "https://example.com/docs")!)

        var settings = persistentStore.settings(for: URL(string: "https://example.com/docs")!)
        settings.contentMode = .desktop
        settings.pageZoom = 1.3
        settings.blockerEnabled = false
        persistentStore.saveSiteSettings(settings)
        persistentStore.saveCurrentPageNote("한글 메모와 中文 메모")

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        let restoredSettings = restored.settings(for: URL(string: "https://example.com/docs")!)
        XCTAssertEqual(restoredSettings.contentMode, .desktop)
        XCTAssertEqual(restoredSettings.pageZoom, 1.3)
        XCTAssertFalse(restoredSettings.blockerEnabled)
        XCTAssertEqual(restored.pageNotes.first?.text, "한글 메모와 中文 메모")

        defaults.removeObject(forKey: key)
        store.resetForTesting()
    }

    func testChangingConfigurationOnlySiteSettingRecreatesVisibleWebView() {
        let (store, _) = makeStore()
        store.open(URL(string: "https://example.com/video")!)
        let originalInstanceID = store.session(for: .primary).instanceID
        var settings = store.settings(for: URL(string: "https://example.com/video")!)
        settings.autoplayEnabled = true

        store.saveSiteSettings(settings)

        XCTAssertNotEqual(store.session(for: .primary).instanceID, originalInstanceID)
        XCTAssertEqual(store.webViewRevision, 1)
    }

    func testPrivacyContentBlockerRulesCompile() async {
        let blocker = BrowserContentBlocker()

        await blocker.prepare()

        XCTAssertNotNil(blocker.ruleList, blocker.errorMessage ?? "Content blocker did not compile")
        XCTAssertNil(blocker.errorMessage)
    }

    func testLegacySnapshotDecodesWithFeatureDefaults() throws {
        let (_, defaults) = makeStore()
        let key = "legacy.snapshot"
        let tabID = UUID()
        let workspaceID = UUID()
        let legacy: [String: Any] = [
            "workspaces": [[
                "id": workspaceID.uuidString,
                "name": "Legacy",
                "tabs": [[
                    "id": tabID.uuidString,
                    "title": "Old tab",
                    "urlString": "https://example.com",
                    "isPinned": false
                ]],
                "primaryTabID": tabID.uuidString,
                "splitEnabled": false,
                "splitRatio": 0.5
            ]],
            "activeWorkspaceID": workspaceID.uuidString,
            "groups": [],
            "bookmarks": [],
            "commandBarCollapsed": false
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)

        XCTAssertEqual(restored.activeWorkspace.name, "Legacy")
        XCTAssertTrue(restored.activeWorkspace.archivedTabs.isEmpty)
        XCTAssertTrue(restored.siteSettings.isEmpty)
        XCTAssertEqual(restored.autoArchiveAfterDays, 14)
        defaults.removeObject(forKey: key)
    }

    private func makeStore() -> (WorkspaceBrowserStore, UserDefaults) {
        let suiteName = "WorkspaceBrowserStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (WorkspaceBrowserStore(defaults: defaults, storageKey: "test.snapshot"), defaults)
    }
}
