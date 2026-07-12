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

@MainActor
@Observable
final class BrowserContentBlocker {
    private(set) var ruleList: WKContentRuleList?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?

    func prepare() async {
        guard ruleList == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        do {
            ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "modot-browser-privacy-v1",
                encodedContentRuleList: Self.rulesJSON
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let rulesJSON = #"""
    [
      {"trigger":{"url-filter":".*doubleclick\\.net/.*","resource-type":["script","image","raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googlesyndication\\.com/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*google-analytics\\.com/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googletagmanager\\.com/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*facebook\\.com/tr/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*segment\\.io/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*segment\\.com/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adservice\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adsystem\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adnxs\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*taboola\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*outbrain\\..*"},"action":{"type":"block"}}
    ]
    """#
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
    static let defaultStorageKey = "modot-browser.downloads.v1"

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

        let sanitized = suggestedFilename.replacingOccurrences(of: "/", with: "-")
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static var downloadsDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("ModotBrowser/Downloads", isDirectory: true)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
