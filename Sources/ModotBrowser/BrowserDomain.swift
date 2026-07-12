import Foundation

enum BrowserPane: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary
    case secondary

    var id: String { rawValue }
    var other: BrowserPane { self == .primary ? .secondary : .primary }
    var compactLabel: String { self == .primary ? "L" : "R" }
}

struct BrowserTabRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var urlString: String
    var isPinned: Bool
    var groupID: UUID?
    var stackID: UUID?
    var lastAccessedAt: Date

    init(
        id: UUID,
        title: String,
        urlString: String,
        isPinned: Bool,
        groupID: UUID?,
        stackID: UUID? = nil,
        lastAccessedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isPinned = isPinned
        self.groupID = groupID
        self.stackID = stackID
        self.lastAccessedAt = lastAccessedAt
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
        case id, title, urlString, isPinned, groupID, stackID, lastAccessedAt
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
    var splitEnabled: Bool
    var splitRatio: Double
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
        tabStacks: [BrowserTabStack] = [],
        archivedTabs: [StoredTabRecord] = [],
        recentlyClosedTabs: [StoredTabRecord] = []
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.splitEnabled = splitEnabled
        self.splitRatio = splitRatio
        self.tabStacks = tabStacks
        self.archivedTabs = archivedTabs
        self.recentlyClosedTabs = recentlyClosedTabs
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
        case id, name, tabs, primaryTabID, secondaryTabID, splitEnabled, splitRatio
        case tabStacks, archivedTabs, recentlyClosedTabs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        tabs = try values.decode([BrowserTabRecord].self, forKey: .tabs)
        primaryTabID = try values.decode(UUID.self, forKey: .primaryTabID)
        secondaryTabID = try values.decodeIfPresent(UUID.self, forKey: .secondaryTabID)
        splitEnabled = try values.decodeIfPresent(Bool.self, forKey: .splitEnabled) ?? false
        splitRatio = try values.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
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

    init(
        id: UUID,
        title: String,
        urlString: String,
        groupID: UUID?,
        isPinned: Bool,
        monitorsStatus: Bool = true
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.groupID = groupID
        self.isPinned = isPinned
        self.monitorsStatus = monitorsStatus
    }

    var url: URL? { BrowserURL.resolve(urlString) }

    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, groupID, isPinned, monitorsStatus
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        urlString = try values.decode(String.self, forKey: .urlString)
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        monitorsStatus = try values.decodeIfPresent(Bool.self, forKey: .monitorsStatus) ?? true
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

struct PageNoteRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var pageKey: String
    var pageTitle: String
    var text: String
    var modifiedAt: Date
}

struct BrowserSnapshot: Codable, Equatable, Sendable {
    var workspaces: [BrowserWorkspace]
    var activeWorkspaceID: UUID
    var groups: [ServiceGroup]
    var bookmarks: [ServiceBookmark]
    var commandBarCollapsed: Bool
    var siteSettings: [SiteSettingsRecord]
    var pageNotes: [PageNoteRecord]
    var autoArchiveAfterDays: Int

    init(
        workspaces: [BrowserWorkspace],
        activeWorkspaceID: UUID,
        groups: [ServiceGroup],
        bookmarks: [ServiceBookmark],
        commandBarCollapsed: Bool,
        siteSettings: [SiteSettingsRecord] = [],
        pageNotes: [PageNoteRecord] = [],
        autoArchiveAfterDays: Int = 14
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.groups = groups
        self.bookmarks = bookmarks
        self.commandBarCollapsed = commandBarCollapsed
        self.siteSettings = siteSettings
        self.pageNotes = pageNotes
        self.autoArchiveAfterDays = autoArchiveAfterDays
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, activeWorkspaceID, groups, bookmarks, commandBarCollapsed
        case siteSettings, pageNotes, autoArchiveAfterDays
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try values.decode([BrowserWorkspace].self, forKey: .workspaces)
        activeWorkspaceID = try values.decode(UUID.self, forKey: .activeWorkspaceID)
        groups = try values.decodeIfPresent([ServiceGroup].self, forKey: .groups) ?? []
        bookmarks = try values.decodeIfPresent([ServiceBookmark].self, forKey: .bookmarks) ?? []
        commandBarCollapsed = try values.decodeIfPresent(Bool.self, forKey: .commandBarCollapsed) ?? false
        siteSettings = try values.decodeIfPresent([SiteSettingsRecord].self, forKey: .siteSettings) ?? []
        pageNotes = try values.decodeIfPresent([PageNoteRecord].self, forKey: .pageNotes) ?? []
        autoArchiveAfterDays = try values.decodeIfPresent(Int.self, forKey: .autoArchiveAfterDays) ?? 14
    }
}

enum BrowserSheetDestination: Identifiable, Equatable {
    case addWorkspace
    case addGroup
    case addBookmark(title: String, url: String)
    case createTabStack
    case siteSettings
    case pageNote
    case pageTools
    case tabArchive
    case downloads

    var id: String {
        switch self {
        case .addWorkspace: "add-workspace"
        case .addGroup: "add-group"
        case .addBookmark: "add-bookmark"
        case .createTabStack: "create-tab-stack"
        case .siteSettings: "site-settings"
        case .pageNote: "page-note"
        case .pageTools: "page-tools"
        case .tabArchive: "tab-archive"
        case .downloads: "downloads"
        }
    }
}

struct SharePayload: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
