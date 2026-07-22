import Foundation

enum BrowserPane: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary
    case secondary
    case tertiary
    case quaternary

    var id: String { rawValue }
    var other: BrowserPane {
        switch self {
        case .primary: .secondary
        case .secondary: .primary
        case .tertiary: .quaternary
        case .quaternary: .tertiary
        }
    }
    /// Slot order used to keep occupancy contiguous (no empty slot before a
    /// filled one).
    static let slotOrder: [BrowserPane] = [.primary, .secondary, .tertiary, .quaternary]
    /// Position label in the 2×2 grid, filled row-major.
    var gridLabel: String {
        switch self {
        case .primary: "1"
        case .secondary: "2"
        case .tertiary: "3"
        case .quaternary: "4"
        }
    }
}

enum BrowserSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical

    func badge(for pane: BrowserPane) -> String {
        switch (self, pane) {
        case (.horizontal, .primary): "L"
        case (.horizontal, .secondary): "R"
        case (.vertical, .primary): "T"
        case (.vertical, .secondary): "B"
        default: pane.gridLabel
        }
    }
}

/// How the canvas is carved up, derived from the occupied pane slots.
/// Compact-width devices only ever see `.single` or a vertical `.pair`
/// (stacked panes, per platform conventions); the grid shapes are iPad-only.
enum BrowserSplitLayout: Equatable, Sendable {
    case single
    case pair(BrowserSplitAxis)
    /// Three panes: two columns on top, the third spanning the bottom row.
    case triple
    /// Four panes in a 2×2 grid.
    case quad
}

/// Which edge of the canvas a dragged tab was dropped on. Left/right create a
/// side-by-side split; top/bottom create a stacked split.
enum SplitPlacement: Equatable, Sendable {
    case leading
    case trailing
    case top
    case bottom

    var axis: BrowserSplitAxis {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    var pane: BrowserPane {
        switch self {
        case .leading, .top: .primary
        case .trailing, .bottom: .secondary
        }
    }
}

struct BrowserTabRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var urlString: String
    var isPinned: Bool
    var groupID: UUID?
    var stackID: UUID?
    var lastAccessedAt: Date
    var preferredPane: BrowserPane?

    init(
        id: UUID,
        title: String,
        urlString: String,
        isPinned: Bool,
        groupID: UUID?,
        stackID: UUID? = nil,
        lastAccessedAt: Date = .now,
        preferredPane: BrowserPane? = nil
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isPinned = isPinned
        self.groupID = groupID
        self.stackID = stackID
        self.lastAccessedAt = lastAccessedAt
        self.preferredPane = preferredPane
    }

    static func start(id: UUID = UUID(), now: Date = .now) -> BrowserTabRecord {
        BrowserTabRecord(
            id: id,
            title: "Start",
            urlString: StartPage.url.absoluteString,
            isPinned: false,
            groupID: nil,
            lastAccessedAt: now
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, isPinned, groupID, stackID, lastAccessedAt, preferredPane
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        urlString = try values.decode(String.self, forKey: .urlString)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        stackID = try values.decodeIfPresent(UUID.self, forKey: .stackID)
        lastAccessedAt = try values.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? .now
        preferredPane = try values.decodeIfPresent(BrowserPane.self, forKey: .preferredPane)
    }
}

struct BrowserTabStack: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
}

struct StoredTabRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var tab: BrowserTabRecord
    var storedAt: Date

    init(tab: BrowserTabRecord, storedAt: Date = .now) {
        id = UUID()
        self.tab = tab
        self.storedAt = storedAt
    }
}

struct BrowserWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var tabs: [BrowserTabRecord]
    var primaryTabID: UUID
    var secondaryTabID: UUID?
    var tertiaryTabID: UUID?
    var quaternaryTabID: UUID?
    var splitEnabled: Bool
    var splitRatio: Double
    /// Top-row share of the height when three or four panes form a grid.
    var splitRowRatio: Double
    var splitAxis: BrowserSplitAxis
    var tabStacks: [BrowserTabStack]
    var archivedTabs: [StoredTabRecord]
    var recentlyClosedTabs: [StoredTabRecord]

    init(
        id: UUID,
        name: String,
        tabs: [BrowserTabRecord],
        primaryTabID: UUID,
        secondaryTabID: UUID?,
        splitEnabled: Bool,
        splitRatio: Double,
        splitAxis: BrowserSplitAxis = .horizontal,
        tertiaryTabID: UUID? = nil,
        quaternaryTabID: UUID? = nil,
        splitRowRatio: Double = 0.5,
        tabStacks: [BrowserTabStack] = [],
        archivedTabs: [StoredTabRecord] = [],
        recentlyClosedTabs: [StoredTabRecord] = []
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.tertiaryTabID = tertiaryTabID
        self.quaternaryTabID = quaternaryTabID
        self.splitEnabled = splitEnabled
        self.splitRatio = splitRatio
        self.splitRowRatio = splitRowRatio
        self.splitAxis = splitAxis
        self.tabStacks = tabStacks
        self.archivedTabs = archivedTabs
        self.recentlyClosedTabs = recentlyClosedTabs
    }

    func tabID(for pane: BrowserPane) -> UUID? {
        switch pane {
        case .primary: primaryTabID
        case .secondary: secondaryTabID
        case .tertiary: tertiaryTabID
        case .quaternary: quaternaryTabID
        }
    }

    mutating func setTabID(_ tabID: UUID?, for pane: BrowserPane) {
        switch pane {
        case .primary: if let tabID { primaryTabID = tabID }
        case .secondary: secondaryTabID = tabID
        case .tertiary: tertiaryTabID = tabID
        case .quaternary: quaternaryTabID = tabID
        }
    }

    /// Panes that currently host a tab, in slot order. Occupancy is kept
    /// contiguous by `normalizePanes`, so this is always a prefix of
    /// `BrowserPane.slotOrder`.
    var occupiedPanes: [BrowserPane] {
        guard splitEnabled else { return [.primary] }
        return BrowserPane.slotOrder.filter { tabID(for: $0) != nil }
    }

    static func fresh(name: String, now: Date = .now) -> BrowserWorkspace {
        let tab = BrowserTabRecord.start(now: now)
        return BrowserWorkspace(
            id: UUID(),
            name: name,
            tabs: [tab],
            primaryTabID: tab.id,
            secondaryTabID: nil,
            splitEnabled: false,
            splitRatio: 0.5
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tabs, primaryTabID, secondaryTabID, tertiaryTabID, quaternaryTabID
        case splitEnabled, splitRatio, splitRowRatio, splitAxis
        case tabStacks, archivedTabs, recentlyClosedTabs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        tabs = try values.decode([BrowserTabRecord].self, forKey: .tabs)
        primaryTabID = try values.decode(UUID.self, forKey: .primaryTabID)
        secondaryTabID = try values.decodeIfPresent(UUID.self, forKey: .secondaryTabID)
        tertiaryTabID = try values.decodeIfPresent(UUID.self, forKey: .tertiaryTabID)
        quaternaryTabID = try values.decodeIfPresent(UUID.self, forKey: .quaternaryTabID)
        splitEnabled = try values.decodeIfPresent(Bool.self, forKey: .splitEnabled) ?? false
        splitRatio = try values.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
        splitRowRatio = try values.decodeIfPresent(Double.self, forKey: .splitRowRatio) ?? 0.5
        splitAxis = try values.decodeIfPresent(BrowserSplitAxis.self, forKey: .splitAxis) ?? .horizontal
        tabStacks = try values.decodeIfPresent([BrowserTabStack].self, forKey: .tabStacks) ?? []
        archivedTabs = try values.decodeIfPresent([StoredTabRecord].self, forKey: .archivedTabs) ?? []
        recentlyClosedTabs = try values.decodeIfPresent([StoredTabRecord].self, forKey: .recentlyClosedTabs) ?? []
    }
}

struct ServiceGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
}

struct ServiceBookmark: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var urlString: String
    var groupID: UUID?
    var isPinned: Bool
    var monitorsStatus: Bool
    /// nil means the bookmark is shared across every workspace.
    var workspaceID: UUID?

    init(
        id: UUID,
        title: String,
        urlString: String,
        groupID: UUID?,
        isPinned: Bool,
        monitorsStatus: Bool = true,
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.groupID = groupID
        self.isPinned = isPinned
        self.monitorsStatus = monitorsStatus
        self.workspaceID = workspaceID
    }

    var url: URL? { BrowserURL.resolve(urlString) }

    func isVisible(in workspaceID: UUID) -> Bool {
        self.workspaceID == nil || self.workspaceID == workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, groupID, isPinned, monitorsStatus, workspaceID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        urlString = try values.decode(String.self, forKey: .urlString)
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        monitorsStatus = try values.decodeIfPresent(Bool.self, forKey: .monitorsStatus) ?? true
        workspaceID = try values.decodeIfPresent(UUID.self, forKey: .workspaceID)
    }
}

enum BrowserContentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case recommended
    case mobile
    case desktop

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum BrowserPermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case allow
    case deny

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct SiteSettingsRecord: Codable, Equatable, Identifiable, Sendable {
    var workspaceID: UUID
    var host: String
    var contentMode: BrowserContentMode = .recommended
    var pageZoom: Double = 1
    var blockerEnabled = true
    var javaScriptEnabled = true
    var autoplayEnabled = false
    var cameraPermission: BrowserPermission = .ask
    var microphonePermission: BrowserPermission = .ask

    var id: String { "\(workspaceID.uuidString)|\(host.lowercased())" }
}

struct BrowserSnapshot: Codable, Equatable, Sendable {
    var workspaces: [BrowserWorkspace]
    var activeWorkspaceID: UUID
    var groups: [ServiceGroup]
    var bookmarks: [ServiceBookmark]
    var commandBarCollapsed: Bool
    var siteSettings: [SiteSettingsRecord]
    var autoArchiveAfterDays: Int

    init(
        workspaces: [BrowserWorkspace],
        activeWorkspaceID: UUID,
        groups: [ServiceGroup],
        bookmarks: [ServiceBookmark],
        commandBarCollapsed: Bool,
        siteSettings: [SiteSettingsRecord] = [],
        autoArchiveAfterDays: Int = 14
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.groups = groups
        self.bookmarks = bookmarks
        self.commandBarCollapsed = commandBarCollapsed
        self.siteSettings = siteSettings
        self.autoArchiveAfterDays = autoArchiveAfterDays
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, activeWorkspaceID, groups, bookmarks, commandBarCollapsed
        case siteSettings, autoArchiveAfterDays
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try values.decode([BrowserWorkspace].self, forKey: .workspaces)
        activeWorkspaceID = try values.decode(UUID.self, forKey: .activeWorkspaceID)
        groups = try values.decodeIfPresent([ServiceGroup].self, forKey: .groups) ?? []
        bookmarks = try values.decodeIfPresent([ServiceBookmark].self, forKey: .bookmarks) ?? []
        commandBarCollapsed = try values.decodeIfPresent(Bool.self, forKey: .commandBarCollapsed) ?? false
        siteSettings = try values.decodeIfPresent([SiteSettingsRecord].self, forKey: .siteSettings) ?? []
        autoArchiveAfterDays = try values.decodeIfPresent(Int.self, forKey: .autoArchiveAfterDays) ?? 14
    }
}

enum BrowserSheetDestination: Identifiable, Equatable {
    case addWorkspace
    case addGroup
    case addBookmark(title: String, url: String)
    case createTabStack
    case siteSettings
    case pageTools
    case developerTools
    case tabArchive
    case downloads

    var id: String {
        switch self {
        case .addWorkspace: "add-workspace"
        case .addGroup: "add-group"
        case .addBookmark: "add-bookmark"
        case .createTabStack: "create-tab-stack"
        case .siteSettings: "site-settings"
        case .pageTools: "page-tools"
        case .developerTools: "developer-tools"
        case .tabArchive: "tab-archive"
        case .downloads: "downloads"
        }
    }
}

/// Transient state for the long-press tab drag interaction: scrubbing across
/// the full-width tab overview at the top, or aiming at a split drop zone at
/// the bottom of the canvas.
struct TabDragState: Equatable {
    let tabID: UUID
    /// nil until the finger moves after the long press is recognized.
    var location: CGPoint?
    var target: TabDragTarget?
}

enum TabDragTarget: Equatable {
    case tab(UUID)
    case split(SplitPlacement)
}

struct SharePayload: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
