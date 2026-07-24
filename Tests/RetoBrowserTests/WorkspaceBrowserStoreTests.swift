import XCTest
import WebKit
@testable import RetoBrowser

@MainActor
final class WorkspaceBrowserStoreTests: XCTestCase {
    func testIslandCollapseKeepsTabShelfWhenTabListIsEnabled() {
        XCTAssertEqual(
            IslandChromePresentation.resolve(isExpanded: false, showsTabs: true),
            .collapsedWithTabs
        )
        XCTAssertEqual(
            IslandChromePresentation.resolve(isExpanded: false, showsTabs: false),
            .collapsed
        )
        XCTAssertEqual(
            IslandChromePresentation.resolve(isExpanded: true, showsTabs: true),
            .expanded
        )
    }

    func testSmallDownwardPageScrollCollapsesExpandedIsland() {
        let (store, _) = makeStore()
        store.islandExpanded = true

        store.collapseIslandForPageScroll()

        XCTAssertFalse(store.islandExpanded)
    }

    func testIslandCollapseScrollGestureUsesAReadingScrollOrProjectedFlick() {
        XCTAssertTrue(
            IslandCollapseScrollGesture.shouldCollapse(
                for: CGPoint(x: 0, y: -44),
                velocity: .zero
            )
        )
        XCTAssertFalse(
            IslandCollapseScrollGesture.shouldCollapse(
                for: CGPoint(x: 0, y: -43),
                velocity: .zero
            )
        )
        XCTAssertTrue(
            IslandCollapseScrollGesture.shouldCollapse(
                for: CGPoint(x: 0, y: -16),
                velocity: CGPoint(x: 0, y: -320)
            )
        )
        XCTAssertFalse(
            IslandCollapseScrollGesture.shouldCollapse(
                for: CGPoint(x: 44, y: -44),
                velocity: .zero
            )
        )
        XCTAssertFalse(
            IslandCollapseScrollGesture.shouldCollapse(
                for: CGPoint(x: 0, y: 44),
                velocity: .zero
            )
        )
    }

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

    func testPrivateWorkspaceUsesMemoryOnlyDataStoreAndIsNotRestored() {
        let (store, defaults) = makeStore()

        store.addWorkspace(name: "Private", isPrivate: true)

        XCTAssertTrue(store.activeWorkspace.isPrivate)
        XCTAssertFalse(store.session(for: .primary).webView.configuration.websiteDataStore.isPersistent)

        let restored = WorkspaceBrowserStore(defaults: defaults, storageKey: "test.snapshot")
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.activeWorkspace.name, "Main")
        XCTAssertFalse(restored.activeWorkspace.isPrivate)
    }

    func testWebsiteDataSummarySeparatesCacheFromLoginStorage() {
        let cache = BrowserWebsiteDataSummary(
            displayName: "static.example",
            dataTypes: [WKWebsiteDataTypeDiskCache]
        )
        let login = BrowserWebsiteDataSummary(
            displayName: "account.example",
            dataTypes: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage]
        )

        XCTAssertTrue(cache.containsCache)
        XCTAssertFalse(cache.containsLoginData)
        XCTAssertEqual(cache.detailText, "Cache")
        XCTAssertTrue(login.containsLoginData)
        XCTAssertEqual(login.detailText, "Cookies & storage")
    }

    func testLegacySiteSettingsDecodeWithSafePermissionDefaults() throws {
        let workspaceID = UUID()
        let json = """
        {
          "workspaceID": "\(workspaceID.uuidString)",
          "host": "example.com",
          "blockerEnabled": false
        }
        """

        let settings = try JSONDecoder().decode(SiteSettingsRecord.self, from: Data(json.utf8))

        XCTAssertEqual(settings.contentMode, .recommended)
        XCTAssertEqual(settings.cameraPermission, .ask)
        XCTAssertEqual(settings.microphonePermission, .ask)
        XCTAssertEqual(settings.motionPermission, .ask)
        XCTAssertFalse(settings.blockerEnabled)
    }

    func testNavigationSecurityBlocksScriptedExternalSchemes() {
        let mailURL = URL(string: "mailto:test@example.com")!
        let sourceURL = URL(string: "https://example.com")!

        XCTAssertEqual(
            BrowserNavigationSecurityPolicy.disposition(
                for: mailURL,
                sourceURL: sourceURL,
                navigationType: .other,
                targetFrameIsMainFrame: true,
                canOpenExternalURL: true
            ),
            .block(reason: "Blocked a website from opening an external app without a direct tap.")
        )
        XCTAssertEqual(
            BrowserNavigationSecurityPolicy.disposition(
                for: mailURL,
                sourceURL: sourceURL,
                navigationType: .linkActivated,
                targetFrameIsMainFrame: true,
                canOpenExternalURL: true
            ),
            .openExternal
        )
    }

    func testNavigationSecurityBlocksRemoteDataURLReplacement() {
        XCTAssertEqual(
            BrowserNavigationSecurityPolicy.disposition(
                for: URL(string: "data:text/html,phishing")!,
                sourceURL: URL(string: "https://example.com")!,
                navigationType: .other,
                targetFrameIsMainFrame: true,
                canOpenExternalURL: false
            ),
            .block(reason: "Blocked a remote page from replacing the tab with local or inline content.")
        )
    }

    func testHTTPAuthenticationPolicyAllowsSecurePersistentServerLogin() {
        let space = URLProtectionSpace(
            host: "secure.example.com",
            port: 443,
            protocol: "https",
            realm: "Admin",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        XCTAssertTrue(BrowserHTTPAuthenticationPolicy.supports(space))
        XCTAssertTrue(BrowserHTTPAuthenticationPolicy.canSave(space, isPrivate: false))
        XCTAssertFalse(BrowserHTTPAuthenticationPolicy.canSave(space, isPrivate: true))
    }

    func testHTTPAuthenticationPolicyDoesNotSaveInsecureOrServerTrustChallenges() {
        let insecure = URLProtectionSpace(
            host: "plain.example.com",
            port: 80,
            protocol: "http",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let trust = URLProtectionSpace(
            host: "secure.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )

        XCTAssertFalse(BrowserHTTPAuthenticationPolicy.canSave(insecure, isPrivate: false))
        XCTAssertFalse(BrowserHTTPAuthenticationPolicy.supports(trust))
    }

    func testSavedCredentialSummaryFormatsDefaultAndCustomPorts() {
        let defaultPort = BrowserSavedCredentialSummary(
            host: "example.com",
            port: 443,
            protocolName: "https",
            realm: "Admin",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            username: "reto"
        )
        let customPort = BrowserSavedCredentialSummary(
            host: "example.com",
            port: 8443,
            protocolName: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            username: "reto"
        )

        XCTAssertEqual(defaultPort.displayHost, "example.com")
        XCTAssertEqual(defaultPort.detailText, "reto · Admin")
        XCTAssertEqual(customPort.displayHost, "example.com:8443")
    }

    func testDownloadFilenameSanitizationPreventsPathTraversalAndControlCharacters() {
        XCTAssertEqual(
            BrowserDownloadManager.sanitizedFilename("../secret\u{0000}/report.pdf"),
            "-secret-report.pdf"
        )
        XCTAssertEqual(BrowserDownloadManager.sanitizedFilename("..."), "Download")
        XCTAssertLessThanOrEqual(BrowserDownloadManager.sanitizedFilename(String(repeating: "a", count: 500)).count, 180)
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

    func testOpenGroupURLsFillsPanesUpToRegularCapAndBackgroundsTheRest() {
        let (store, _) = makeStore()
        let urls = (1...5).map { URL(string: "https://service\($0).example.ts.net")! }

        let placed = store.openGroupURLs(urls)

        XCTAssertEqual(placed, 4)
        XCTAssertEqual(store.splitLayout, .quad)
        // Every occupied pane shows a different tab — one WKWebView must
        // never mount twice.
        let paneTabs = store.visiblePanes.map { store.selectedTabID(for: $0) }
        XCTAssertEqual(Set(paneTabs).count, 4)
        XCTAssertEqual(
            Set(store.visiblePanes.map { store.selectedTab(for: $0).urlString }),
            Set(urls.prefix(4).map(\.absoluteString))
        )

        // The URL that didn't fit becomes a background tab: present, not
        // occupying any pane.
        let overflowURL = urls[4].absoluteString
        XCTAssertTrue(store.activeWorkspace.tabs.contains(where: { $0.urlString == overflowURL }))
        XCTAssertFalse(store.visiblePanes.contains(where: { store.selectedTab(for: $0).urlString == overflowURL }))
    }

    func testOpenGroupURLsCapsAtTwoPanesOnCompactWidth() {
        let (store, _) = makeStore()
        store.layoutIsCompact = true
        let urls = (1...3).map { URL(string: "https://service\($0).example.ts.net")! }

        let placed = store.openGroupURLs(urls)

        XCTAssertEqual(placed, 2)
        XCTAssertEqual(store.visiblePanes.count, 2)
        let overflowURL = urls[2].absoluteString
        XCTAssertTrue(store.activeWorkspace.tabs.contains(where: { $0.urlString == overflowURL }))
    }

    func testOpenGroupOnlyOpensBookmarksVisibleInTheActiveWorkspace() {
        let (store, _) = makeStore()
        let mainID = store.activeWorkspaceID
        let group = store.groups.first ?? ServiceGroup(id: UUID(), name: "Tailnet")
        if store.groups.isEmpty { store.groups = [group] }

        store.addBookmark(
            title: "Shared", urlString: "https://shared.example.ts.net",
            groupID: group.id, isPinned: false, workspaceID: nil
        )
        store.addWorkspace(name: "Ops")
        store.addBookmark(
            title: "OpsOnly", urlString: "https://ops-only.example.ts.net",
            groupID: group.id, isPinned: false, workspaceID: store.activeWorkspaceID
        )

        store.selectWorkspace(mainID)
        let placed = store.openGroup(group.id)

        XCTAssertEqual(placed, 1)
        XCTAssertEqual(store.selectedTab(for: .primary).urlString, "https://shared.example.ts.net")
    }

    private func makeStore() -> (WorkspaceBrowserStore, UserDefaults) {
        let suiteName = "WorkspaceBrowserStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (WorkspaceBrowserStore(defaults: defaults, storageKey: "test.snapshot"), defaults)
    }
}
