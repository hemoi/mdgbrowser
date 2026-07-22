import Foundation
import Observation
import SwiftUI

/// One saved page selection (or, when nothing was selected, just the page
/// link) that the pet "absorbed". Ported from pet-for-safari's `Scrap`,
/// trimmed to the fields the browser-appropriate flow actually needs: no
/// folders/tags/AI enrichment, just enough provenance to find the page
/// again.
struct BrowserScrap: Codable, Equatable, Identifiable, Sendable {
    static let maxSelectedTextLength = 2000
    static let maxTitleLength = 300

    let id: UUID
    var pageTitle: String
    var pageURL: String
    /// The selected text, or empty when the user saved just the page link.
    var selectedText: String
    var createdAt: Date

    /// Builds a scrap from untrusted web-page input, clamping every field.
    /// Fails only when the page URL isn't a real http(s) address.
    init?(pageTitle: String, pageURL: String, selectedText: String, createdAt: Date = Date()) {
        guard let url = URL(string: pageURL), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        id = UUID()
        self.pageURL = pageURL
        self.pageTitle = String(
            pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength)
        )
        self.selectedText = String(
            selectedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSelectedTextLength)
        )
        self.createdAt = createdAt
    }

    var isLinkOnly: Bool { selectedText.isEmpty }

    /// De-dupes back-to-back saves of the same selection on the same page.
    var dedupKey: String { "\(pageURL)|\(selectedText)" }
}

/// File-backed scrap storage under Application Support — one JSON file per
/// scrap, same shape as pet-for-safari's `ScrapStore`, minus the App Group
/// plumbing (the browser has no extension process writing concurrently).
final class BrowserScrapStore {
    enum StoreError: Error, LocalizedError {
        case invalidScrap

        var errorDescription: String? {
            switch self {
            case .invalidScrap:
                "That page couldn't be saved as a scrap."
            }
        }
    }

    /// Duplicate saves of the same selection on the same page within this
    /// window return the existing scrap instead of creating a new one.
    static let dedupWindow: TimeInterval = 10 * 60

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetoBrowser/Scraps", isDirectory: true)
    }

    private let directory: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(directory: URL = BrowserScrapStore.defaultDirectory) {
        self.directory = directory
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func save(_ scrap: BrowserScrap) throws -> BrowserScrap {
        if let existing = try? findRecentDuplicate(of: scrap) {
            return existing
        }
        try ensureDirectory()
        let data = try encoder.encode(scrap)
        try data.write(to: fileURL(for: scrap.id), options: .atomic)
        return scrap
    }

    func list() -> [BrowserScrap] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let scraps: [BrowserScrap] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(BrowserScrap.self, from: data)
            }
        return scraps.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func findRecentDuplicate(of scrap: BrowserScrap) throws -> BrowserScrap? {
        let cutoff = scrap.createdAt.addingTimeInterval(-Self.dedupWindow)
        return list().first { $0.dedupKey == scrap.dedupKey && $0.createdAt >= cutoff }
    }
}

/// Reads the current page's selection (or falls back to just the link) and
/// saves it as a scrap, then drives the pet's absorb reaction. Lives outside
/// `BrowserPetStore` because it needs the active `BrowserSession` to read the
/// page — the store itself stays session-agnostic.
@MainActor
func saveCurrentPageAsScrap(
    session: BrowserSession,
    scrapStore: BrowserScrapStore,
    petStore: BrowserPetStore
) async -> Bool {
    struct SelectionPayload: Decodable {
        let selection: String
        let title: String
        let url: String
    }

    guard session.currentURL != nil else {
        petStore.showMessage("Open a webpage first.")
        return false
    }

    let script = """
    (function () {
      var selection = window.getSelection ? String(window.getSelection()) : "";
      return { selection: selection, title: document.title || "", url: window.location.href };
    })()
    """

    do {
        let raw = try await session.runDeveloperScript(script)
        let payload = try decodePayload(raw, as: SelectionPayload.self)
        guard let scrap = BrowserScrap(
            pageTitle: payload.title,
            pageURL: payload.url,
            selectedText: payload.selection
        ) else {
            petStore.showMessage("This page can't be saved as a scrap.")
            return false
        }
        try scrapStore.save(scrap)
        petStore.notify(.scrapSaved)
        petStore.showMessage(scrap.isLinkOnly ? "Saved this page." : "Saved that to your scraps.")
        return true
    } catch {
        petStore.showMessage("Couldn't save that scrap.")
        return false
    }
}

/// `runDeveloperScript` hands back either a pretty-printed JSON string (for
/// object results, our case here) or a bare string. Decode defensively.
private func decodePayload<T: Decodable>(_ raw: String, as type: T.Type) throws -> T {
    guard let data = raw.data(using: .utf8) else {
        throw BrowserScrapStore.StoreError.invalidScrap
    }
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - UI

struct ScrapListSheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let store: BrowserScrapStore
    /// Opens a scrap's page in a new browser tab and dismisses this sheet.
    let openLink: (URL) -> Void

    @State private var scraps: [BrowserScrap] = []

    var body: some View {
        NavigationStack {
            Group {
                if scraps.isEmpty {
                    ContentUnavailableView {
                        Label("No Scraps Yet", systemImage: "bookmark")
                    } description: {
                        Text("Select text on a page and use the pet's Save Scrap action to keep it here.")
                    }
                } else {
                    List {
                        ForEach(scraps) { scrap in
                            NavigationLink {
                                ScrapDetailView(scrap: scrap, openLink: openLink) {
                                    delete(scrap)
                                }
                                .environment(theme)
                            } label: {
                                ScrapRow(scrap: scrap)
                            }
                        }
                        .onDelete(perform: deleteAtOffsets)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Scraps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        scraps = store.list()
    }

    private func delete(_ scrap: BrowserScrap) {
        store.delete(id: scrap.id)
        reload()
    }

    private func deleteAtOffsets(_ offsets: IndexSet) {
        for index in offsets {
            store.delete(id: scraps[index].id)
        }
        reload()
    }
}

private struct ScrapRow: View {
    let scrap: BrowserScrap

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scrap.isLinkOnly ? (scrap.pageTitle.isEmpty ? scrap.pageURL : scrap.pageTitle) : scrap.selectedText)
                .font(.system(size: 14))
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(scrap.pageTitle.isEmpty ? scrap.pageURL : scrap.pageTitle)
                    .lineLimit(1)
                Text(scrap.createdAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ScrapDetailView: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let scrap: BrowserScrap
    let openLink: (URL) -> Void
    let onDelete: () -> Void

    var body: some View {
        List {
            if !scrap.isLinkOnly {
                Section("Saved text") {
                    Text(scrap.selectedText)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            Section("Source") {
                if let url = URL(string: scrap.pageURL) {
                    Button {
                        openLink(url)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if !scrap.pageTitle.isEmpty {
                                Text(scrap.pageTitle).foregroundStyle(theme.label)
                            }
                            Text(scrap.pageURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Text(scrap.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Scrap", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scrap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
