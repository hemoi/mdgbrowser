import XCTest
@testable import RetoBrowser

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

    func testSiteSettingsPersist() {
        let (store, defaults) = makeStore()
        let key = "feature.snapshot"
        let persistentStore = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        persistentStore.open(URL(string: "https://example.com/docs")!)

        var settings = persistentStore.settings(for: URL(string: "https://example.com/docs")!)
        settings.contentMode = .desktop
        settings.pageZoom = 1.3
        settings.blockerEnabled = false
        persistentStore.saveSiteSettings(settings)

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        let restoredSettings = restored.settings(for: URL(string: "https://example.com/docs")!)
        XCTAssertEqual(restoredSettings.contentMode, .desktop)
        XCTAssertEqual(restoredSettings.pageZoom, 1.3)
        XCTAssertFalse(restoredSettings.blockerEnabled)

        defaults.removeObject(forKey: key)
        store.resetForTesting()
    }

    func testPlaceTabRightEnablesSplitKeepingCurrentPageLeft() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let secondID = store.addTab()

        store.placeTab(secondID, in: .secondary)

        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.selectedTabID(for: .primary), firstID)
        XCTAssertEqual(store.selectedTabID(for: .secondary), secondID)
        XCTAssertEqual(store.activePane, .secondary)
    }

    func testPlaceTabLeftMovesCurrentPageRight() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let secondID = store.addTab()

        store.placeTab(secondID, in: .primary)

        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.selectedTabID(for: .primary), secondID)
        XCTAssertEqual(store.selectedTabID(for: .secondary), firstID)
        XCTAssertEqual(store.activePane, .primary)
    }

    func testPlacingOnlyTabIntoSplitCreatesCompanion() {
        let (store, _) = makeStore()
        let onlyID = store.selectedTabID(for: .primary)

        store.placeTab(onlyID, in: .secondary)

        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.activeWorkspace.tabs.count, 2)
        XCTAssertEqual(store.selectedTabID(for: .secondary), onlyID)
        XCTAssertNotEqual(store.selectedTabID(for: .primary), onlyID)
    }

    func testTabRemembersPaneAcrossSplitToggle() {
        let (store, _) = makeStore()
        store.toggleSplit()
        let rightID = store.selectedTabID(for: .secondary)

        store.toggleSplit()
        store.toggleSplit()

        XCTAssertEqual(store.selectedTabID(for: .secondary), rightID)
    }

    func testTapOnVisibleTabFocusesItsPaneWithoutSwapping() {
        let (store, _) = makeStore()
        store.toggleSplit()
        let leftID = store.selectedTabID(for: .primary)
        let rightID = store.selectedTabID(for: .secondary)
        XCTAssertEqual(store.activePane, .secondary)

        store.handleTabTap(leftID)

        XCTAssertEqual(store.activePane, .primary)
        XCTAssertEqual(store.selectedTabID(for: .primary), leftID)
        XCTAssertEqual(store.selectedTabID(for: .secondary), rightID)
    }

    func testTapOnUnplacedTabAsksForPaneThenPlacementSticks() {
        let (store, _) = makeStore()
        let unplacedID = store.addTab()
        let lastID = store.addTab()
        store.toggleSplit()
        XCTAssertNil(store.paneShowing(unplacedID))

        store.handleTabTap(unplacedID)
        XCTAssertEqual(store.panePlacementPromptTabID, unplacedID)

        store.placeTab(unplacedID, in: .primary)
        XCTAssertNil(store.panePlacementPromptTabID)
        XCTAssertEqual(store.selectedTabID(for: .primary), unplacedID)

        // Once placed left, a plain tap keeps returning it to the left pane.
        store.handleTabTap(lastID)
        XCTAssertEqual(store.selectedTabID(for: .primary), lastID)
        store.handleTabTap(unplacedID)
        XCTAssertEqual(store.selectedTabID(for: .primary), unplacedID)
        XCTAssertEqual(store.activePane, .primary)
    }

    func testAddPaneFillsGridUpToFourOnRegularWidth() {
        let (store, _) = makeStore()

        store.addPane()
        XCTAssertEqual(store.visiblePanes, [.primary, .secondary])
        XCTAssertEqual(store.splitLayout, .pair(.horizontal))

        store.addPane()
        XCTAssertEqual(store.visiblePanes, [.primary, .secondary, .tertiary])
        XCTAssertEqual(store.splitLayout, .triple)

        store.addPane()
        XCTAssertEqual(store.splitLayout, .quad)
        XCTAssertFalse(store.canAddPane)

        // Every pane must show a different tab; one WKWebView cannot mount twice.
        let paneTabs = store.visiblePanes.map { store.selectedTabID(for: $0) }
        XCTAssertEqual(Set(paneTabs).count, 4)
    }

    func testCompactWidthStacksPanesAndCapsAtTwo() {
        let (store, _) = makeStore()
        store.layoutIsCompact = true

        store.addPane()

        XCTAssertEqual(store.splitLayout, .pair(.vertical))
        XCTAssertFalse(store.canAddPane)
        XCTAssertEqual(store.visiblePanes, [.primary, .secondary])
    }

    func testCompactWidthClipsGridBuiltOnIPad() {
        let (store, _) = makeStore()
        store.addPane()
        store.addPane()
        store.addPane()
        XCTAssertEqual(store.splitLayout, .quad)

        // Rotating into a compact width hides the extra panes without
        // discarding them.
        store.layoutIsCompact = true
        XCTAssertEqual(store.visiblePanes, [.primary, .secondary])
        XCTAssertEqual(store.splitLayout, .pair(.vertical))

        store.layoutIsCompact = false
        XCTAssertEqual(store.splitLayout, .quad)
    }

    func testClosingAPaneCompactsRemainingSlots() {
        let (store, _) = makeStore()
        store.addPane()
        store.addPane()
        let thirdID = store.selectedTabID(for: .tertiary)

        store.closePane(.secondary)

        XCTAssertEqual(store.visiblePanes, [.primary, .secondary])
        XCTAssertEqual(store.selectedTabID(for: .secondary), thirdID)
        XCTAssertNil(store.activeWorkspace.tertiaryTabID)
    }

    func testRowRatioIsClampedIndependentlyOfColumnRatio() {
        let (store, _) = makeStore()

        store.setSplitRowRatio(0.95)
        XCTAssertEqual(store.activeWorkspace.splitRowRatio, 0.75)
        XCTAssertEqual(store.activeWorkspace.splitRatio, 0.5)
    }

    func testFinishTabDragPlacesDraggedTabInSplit() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let draggedID = store.addTab()

        store.beginTabDrag(draggedID)
        store.updateTabDrag(location: CGPoint(x: 40, y: 600))
        store.updateTabDragTarget(.split(.leading))
        store.finishTabDrag()

        XCTAssertNil(store.tabDragState)
        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.activeWorkspace.splitAxis, .horizontal)
        XCTAssertEqual(store.selectedTabID(for: .primary), draggedID)
        XCTAssertEqual(store.selectedTabID(for: .secondary), firstID)
    }

    func testDroppingOnBottomEdgeCreatesStackedSplit() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let draggedID = store.addTab()

        store.beginTabDrag(draggedID)
        store.updateTabDragTarget(.split(.bottom))
        store.finishTabDrag()

        XCTAssertTrue(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.activeWorkspace.splitAxis, .vertical)
        XCTAssertEqual(store.selectedTabID(for: .primary), firstID)
        XCTAssertEqual(store.selectedTabID(for: .secondary), draggedID)
        XCTAssertEqual(store.activePane, .secondary)
    }

    func testFinishTabDragOnOverviewSelectsHoveredTab() {
        let (store, _) = makeStore()
        let firstID = store.selectedTabID(for: .primary)
        let draggedID = store.addTab()

        store.beginTabDrag(draggedID)
        store.updateTabDragTarget(.tab(firstID))
        store.finishTabDrag()

        XCTAssertNil(store.tabDragState)
        XCTAssertFalse(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.selectedTabID(for: .primary), firstID)
    }

    func testClosingSecondaryTabWithNoReplacementEndsSplit() {
        let (store, _) = makeStore()
        store.toggleSplit()
        let secondaryID = store.selectedTabID(for: .secondary)

        store.closeTab(secondaryID)

        XCTAssertFalse(store.activeWorkspace.splitEnabled)
        XCTAssertEqual(store.activePane, .primary)
        XCTAssertNotEqual(store.selectedTabID(for: .secondary), secondaryID)
    }

    func testSplitPanesNeverShareOneTab() {
        let (store, _) = makeStore()
        store.addTab()
        store.addTab()
        store.toggleSplit()

        store.closeTab(store.selectedTabID(for: .secondary))

        if store.activeWorkspace.splitEnabled {
            XCTAssertNotEqual(
                store.selectedTabID(for: .primary),
                store.selectedTabID(for: .secondary)
            )
        }
    }

    func testCorruptSplitSnapshotSharingOneTabIsRepairedOnLaunch() throws {
        let (_, defaults) = makeStore()
        let key = "corrupt.split.snapshot"
        let tabID = UUID()
        let workspaceID = UUID()
        let corrupt: [String: Any] = [
            "workspaces": [[
                "id": workspaceID.uuidString,
                "name": "Corrupt",
                "tabs": [[
                    "id": tabID.uuidString,
                    "title": "Only tab",
                    "urlString": "https://example.com",
                    "isPinned": false
                ]],
                "primaryTabID": tabID.uuidString,
                "secondaryTabID": tabID.uuidString,
                "splitEnabled": true,
                "splitRatio": 0.5
            ]],
            "activeWorkspaceID": workspaceID.uuidString,
            "groups": [],
            "bookmarks": [],
            "commandBarCollapsed": false
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: corrupt), forKey: key)

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)

        XCTAssertFalse(restored.activeWorkspace.splitEnabled)
        XCTAssertNil(restored.activeWorkspace.secondaryTabID)
        defaults.removeObject(forKey: key)
    }

    func testWorkspaceScopedBookmarkVisibility() {
        let (store, _) = makeStore()
        let mainID = store.activeWorkspaceID
        store.addBookmark(
            title: "Scoped", urlString: "https://scoped.example.ts.net",
            groupID: nil, isPinned: true, workspaceID: mainID
        )
        store.addBookmark(
            title: "Shared", urlString: "https://shared.example.ts.net",
            groupID: nil, isPinned: true, workspaceID: nil
        )

        XCTAssertEqual(store.visibleBookmarks.count, 2)

        store.addWorkspace(name: "Ops")

        XCTAssertEqual(store.visibleBookmarks.map(\.title), ["Shared"])
        XCTAssertEqual(store.pinnedBookmarks.map(\.title), ["Shared"])

        store.selectWorkspace(mainID)
        XCTAssertEqual(store.visibleBookmarks.count, 2)
    }

    func testBookmarkWorkspaceAssignmentPersists() {
        let (store, defaults) = makeStore()
        let key = "bookmark.workspace.snapshot"
        let persistentStore = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        persistentStore.addBookmark(
            title: "Scoped", urlString: "https://scoped.example.ts.net",
            groupID: nil, isPinned: false, workspaceID: persistentStore.activeWorkspaceID
        )

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(restored.bookmarks.first?.workspaceID, restored.activeWorkspaceID)

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
