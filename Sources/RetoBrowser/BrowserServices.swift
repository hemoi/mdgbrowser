import Foundation
import Observation
import WebKit

enum ServiceReachability: Equatable, Sendable {
    case idle
    case checking
    case online(latencyMilliseconds: Int, statusCode: Int?)
    case offline(message: String)

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ServiceStatusMonitor {
    private(set) var states: [UUID: ServiceReachability] = [:]
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func state(for bookmarkID: UUID) -> ServiceReachability {
        states[bookmarkID] ?? .idle
    }

    func refresh(_ bookmarks: [ServiceBookmark]) {
        refreshTask?.cancel()
        let targets = bookmarks.filter(\.monitorsStatus)

        for bookmark in targets {
            states[bookmark.id] = .checking
        }

        refreshTask = Task { [weak self] in
            for bookmark in targets {
                guard !Task.isCancelled, let self else { return }
                guard let url = bookmark.url else {
                    self.states[bookmark.id] = .offline(message: "Invalid address")
                    continue
                }

                let startedAt = Date()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.httpMethod = "HEAD"

                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let latency = max(Int(Date().timeIntervalSince(startedAt) * 1_000), 1)
                    let code = (response as? HTTPURLResponse)?.statusCode
                    self.states[bookmark.id] = .online(latencyMilliseconds: latency, statusCode: code)
                } catch is CancellationError {
                    return
                } catch {
                    self.states[bookmark.id] = .offline(message: error.localizedDescription)
                }
            }
            self?.lastCheckedAt = .now
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

/// Errors surfaced while assembling the bundled ad/tracker-blocking rule
/// list. These are reported via `BrowserContentBlocker.errorMessage`
/// rather than thrown across the UI boundary.
enum ContentBlockerAssemblyError: LocalizedError {
    case bundleResourceMissing
    case invalidResource(String)
    case networkRuleBudgetExceeded(count: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing:
            return "Bundled ad-blocking list is missing from the app."
        case .invalidResource(let name):
            return "Bundled ad-blocking resource '\(name)' is not valid JSON."
        case .networkRuleBudgetExceeded(let count, let limit):
            return "Bundled ad/tracker rule set (\(count) rules) exceeds WebKit's per-list compile limit (\(limit)); ad blocking is disabled until the bundle is trimmed."
        }
    }
}

/// Version/rule-count metadata for the bundled `Resources/ContentBlocker`
/// data, written by `Resources/ContentBlocker/tools/convert_filter_lists.rb`
/// alongside the rule JSON. `version` is folded into the
/// `WKContentRuleListStore` identifier so that shipping an updated filter
/// list invalidates WebKit's on-disk compiled-rule-list cache; an unchanged
/// version reuses the cached compiled list and never recompiles.
struct ContentBlockerManifest: Decodable, Equatable {
    var version: String
    var totalRulesWithCosmetic: Int
    var totalRulesWithoutCosmetic: Int
    var maxRulesPerCompiledList: Int

    /// Cosmetic (element-hiding) rules are nice-to-have; if a future list
    /// update pushes the combined count over WebKit's practical per-list
    /// ceiling, they are the first thing dropped so the network-level
    /// ad/tracker blocking (the part that actually matters) keeps working.
    /// This is a deterministic function of the manifest, so both a fresh
    /// compile and a cache hit for the same `version` agree on it without
    /// re-reading the rule JSON.
    var includesCosmeticRules: Bool {
        totalRulesWithCosmetic <= maxRulesPerCompiledList
    }

    var activeRuleCount: Int {
        includesCosmeticRules ? totalRulesWithCosmetic : totalRulesWithoutCosmetic
    }
}

@MainActor
@Observable
final class BrowserContentBlocker {
    private(set) var ruleList: WKContentRuleList?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    /// Real rule count from the bundled manifest — WKContentRuleList itself
    /// never reports how many *requests* it actually blocked at runtime, so
    /// this is the compiled rule count, not a live blocked-request tally.
    private(set) var activeRuleCount: Int?
    private(set) var listVersion: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundle: Bundle

    private static let identifierPrefix = "reto-browser.privacy."
    private static let lastIdentifierDefaultsKey = "reto-browser.contentblocker.last-identifier.v1"

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    func prepare() async {
        guard ruleList == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        do {
            guard let directory = Self.resourceDirectory(in: bundle) else {
                throw ContentBlockerAssemblyError.bundleResourceMissing
            }
            let manifest = try Self.loadManifest(in: directory)
            let identifier = Self.identifierPrefix + manifest.version
            let store = WKContentRuleListStore.default()!

            // Reuse WebKit's own on-disk compiled-list cache when the
            // bundled list version hasn't changed. This is what keeps a
            // normal launch from recompiling ~114k rules every time.
            //
            // `contentRuleList(forIdentifier:)` is a *lookup-only* call, and
            // on a store that has never compiled anything yet (a fresh app
            // install, or a fresh WKContentRuleListStore.default() database
            // like in a clean simulator/test run) it does not resolve to
            // `nil` for a plain cache miss the way the API's shape suggests
            // -- it throws `WKErrorDomain` code 7 ("Rule list lookup
            // failed: Unspecified error during lookup.") instead, in well
            // under a millisecond. That is the actual, confirmed cause of
            // the ad blocker's "compile failed" symptom: `prepare()` used
            // to let that error propagate straight to the `catch` below,
            // so the *real* compile of the bundled ads/trackers/cosmetic
            // JSON a few lines down was never even reached -- the bundled
            // rule data itself was never at fault (every fragment, and the
            // full merged payload, compiles cleanly once this lookup is
            // bypassed; see ContentBlockerTests for the direct proof).
            // Treat a thrown lookup the same as a cache miss and fall
            // through to a fresh compile, which always works because
            // `compileContentRuleList` creates the on-disk store as
            // needed instead of assuming it already exists.
            let cachedLookup: WKContentRuleList?
            do {
                cachedLookup = try await store.contentRuleList(forIdentifier: identifier)
            } catch {
                cachedLookup = nil
            }
            if let cached = cachedLookup {
                ruleList = cached
                activeRuleCount = manifest.activeRuleCount
                listVersion = manifest.version
                errorMessage = nil
                return
            }

            let encoded = try Self.mergedRuleListJSON(directory: directory, manifest: manifest)
            let compiled = try await store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encoded
            )
            ruleList = compiled
            activeRuleCount = manifest.activeRuleCount
            listVersion = manifest.version
            errorMessage = nil

            await Self.retireStaleIdentifiers(current: identifier, store: store, defaults: defaults)
            defaults.set(identifier, forKey: Self.lastIdentifierDefaultsKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Bundle assembly (nonisolated: pure, testable without the
    // main-actor + WebKit runtime).

    nonisolated static func resourceDirectory(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "ContentBlocker", withExtension: nil)
    }

    nonisolated static func loadManifest(in directory: URL) throws -> ContentBlockerManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(ContentBlockerManifest.self, from: data)
    }

    /// Concatenates the bundled rule-list JSON fragments (ads, trackers,
    /// optionally cosmetic-lite) into one encoded `WKContentRuleList`
    /// payload. Every fragment is itself a pre-validated compact JSON
    /// array (produced by the conversion tool), so this is a cheap textual
    /// splice rather than a full parse/re-encode of ~15MB of rule data on
    /// every cold compile.
    nonisolated static func mergedRuleListJSON(directory: URL, manifest: ContentBlockerManifest) throws -> String {
        guard manifest.totalRulesWithoutCosmetic <= manifest.maxRulesPerCompiledList else {
            throw ContentBlockerAssemblyError.networkRuleBudgetExceeded(
                count: manifest.totalRulesWithoutCosmetic,
                limit: manifest.maxRulesPerCompiledList
            )
        }

        var names = ["ads.json", "trackers.json"]
        if manifest.includesCosmeticRules {
            names.append("cosmetic-lite.json")
        }

        let fragments = try names.map { try arrayBody(named: $0, in: directory) }
        let joined = fragments.filter { !$0.isEmpty }.joined(separator: ",")
        return "[" + joined + "]"
    }

    /// Reads a bundled `[...]`-shaped JSON file and returns just the inside
    /// of the brackets, so multiple arrays can be spliced together.
    nonisolated private static func arrayBody(named name: String, in directory: URL) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContentBlockerAssemblyError.invalidResource(name)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw ContentBlockerAssemblyError.invalidResource(name)
        }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func retireStaleIdentifiers(
        current: String,
        store: WKContentRuleListStore,
        defaults: UserDefaults
    ) async {
        guard let previous = defaults.string(forKey: lastIdentifierDefaultsKey), previous != current else { return }
        try? await store.removeContentRuleList(forIdentifier: previous)
    }
}

enum BrowserDownloadState: String, Codable, Equatable, Sendable {
    case downloading
    case completed
    case failed
}

struct BrowserDownloadRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fileName: String
    var sourceURLString: String?
    var localURLString: String?
    var startedAt: Date
    var state: BrowserDownloadState
    var errorMessage: String?

    var localURL: URL? {
        guard let localURLString else { return nil }
        return URL(string: localURLString)
    }
}

@MainActor
@Observable
final class BrowserDownloadManager: NSObject, WKDownloadDelegate {
    static let defaultStorageKey = "reto-browser.downloads.v1"

    private(set) var records: [BrowserDownloadRecord]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var downloadIDs: [ObjectIdentifier: UUID] = [:]

    init(defaults: UserDefaults = .standard, storageKey: String = BrowserDownloadManager.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BrowserDownloadRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        super.init()
    }

    func attach(_ download: WKDownload, sourceURL: URL?) {
        let id = UUID()
        downloadIDs[ObjectIdentifier(download)] = id
        records.insert(
            BrowserDownloadRecord(
                id: id,
                fileName: sourceURL?.lastPathComponent.nonEmpty ?? "Download",
                sourceURLString: sourceURL?.absoluteString,
                localURLString: nil,
                startedAt: .now,
                state: .downloading,
                errorMessage: nil
            ),
            at: 0
        )
        download.delegate = self
        persist()
    }

    func addGeneratedFile(_ url: URL, sourceURL: URL?) {
        records.insert(
            BrowserDownloadRecord(
                id: UUID(),
                fileName: url.lastPathComponent,
                sourceURLString: sourceURL?.absoluteString,
                localURLString: url.absoluteString,
                startedAt: .now,
                state: .completed,
                errorMessage: nil
            ),
            at: 0
        )
        persist()
    }

    func delete(_ recordID: UUID) {
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        if let url = record.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        records.removeAll(where: { $0.id == recordID })
        persist()
    }

    func clearFinished() {
        for record in records where record.state != .downloading {
            if let url = record.localURL { try? FileManager.default.removeItem(at: url) }
        }
        records.removeAll(where: { $0.state != .downloading })
        persist()
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let id = downloadIDs[ObjectIdentifier(download)]
        let destination = uniqueDestination(for: suggestedFilename)
        if let id, let index = records.firstIndex(where: { $0.id == id }) {
            records[index].fileName = destination.lastPathComponent
            records[index].localURLString = destination.absoluteString
            persist()
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, state: .completed, message: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        finish(download, state: .failed, message: error.localizedDescription)
    }

    private func finish(_ download: WKDownload, state: BrowserDownloadState, message: String?) {
        let key = ObjectIdentifier(download)
        guard let id = downloadIDs.removeValue(forKey: key),
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        records[index].errorMessage = message
        persist()
    }

    private func uniqueDestination(for suggestedFilename: String) -> URL {
        let directory = Self.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )

        let sanitized = Self.sanitizedFilename(suggestedFilename)
        let proposed = directory.appendingPathComponent(sanitized.nonEmpty ?? "Download")
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }

        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for suffix in 2...999 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(sanitized)")
    }

    static func sanitizedFilename(_ suggestedFilename: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let components = suggestedFilename.precomposedStringWithCanonicalMapping.components(separatedBy: forbidden)
        var sanitized = components.filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if sanitized.count > 180 {
            let suffix = String(sanitized.suffix(40))
            sanitized = String(sanitized.prefix(139)) + "-" + suffix
        }
        return sanitized.nonEmpty ?? "Download"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static var downloadsDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("RetoBrowser/Downloads", isDirectory: true)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
