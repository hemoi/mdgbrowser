import Foundation
import Observation
import SwiftUI

/// A pet listed by the codex-pets.net public API.
struct CodexPetSummary: Codable, Equatable, Identifiable, Sendable {
    struct ValidationReport: Codable, Equatable, Sendable {
        var atlasSize: String?
        var cellSize: String?
    }

    let id: String
    var displayName: String
    var description: String?
    /// Single-frame 192×208 card image. (previewUrl is a wide filmstrip of
    /// every frame — useless as a thumbnail.)
    var posterUrl: String?
    var previewUrl: String?
    var spritesheetUrl: String
    var validationReport: ValidationReport?

    /// Grid derived from the validation report ("1536x2288" atlas with
    /// "192x208" cells → 8 columns × 11 rows). Falls back to the classic
    /// 8×9 layout when the report is missing.
    var grid: (columns: Int, rows: Int) {
        guard let atlas = Self.parseSize(validationReport?.atlasSize),
              let cell = Self.parseSize(validationReport?.cellSize),
              cell.width > 0, cell.height > 0 else {
            return (8, 9)
        }
        let columns = Int((atlas.width / cell.width).rounded())
        let rows = Int((atlas.height / cell.height).rounded())
        guard columns > 0, rows > 0 else { return (8, 9) }
        return (columns, rows)
    }

    var installable: InstalledCodexPet {
        let grid = grid
        return InstalledCodexPet(
            id: id,
            displayName: displayName,
            columns: grid.columns,
            rows: grid.rows
        )
    }

    private static func parseSize(_ value: String?) -> (width: Double, height: Double)? {
        guard let parts = value?.lowercased().split(separator: "x"),
              parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return nil
        }
        return (width, height)
    }
}

struct CodexPetsPage: Codable {
    var pets: [CodexPetSummary]
    var page: Int
    var pageSize: Int
    var total: Int
    var totalPages: Int
}

/// Browses and downloads pets from https://codex-pets.net.
@MainActor
@Observable
final class CodexPetCatalog {
    static let baseURL = URL(string: "https://codex-pets.net")!

    var pets: [CodexPetSummary] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var downloadingPetIDs: Set<String> = []
    private(set) var page = 0
    private(set) var total = 0
    private(set) var totalPages = 1
    private(set) var query = ""

    @ObservationIgnored private let session: URLSession = .shared
    @ObservationIgnored private var requestID = UUID()

    func loadIfNeeded(query: String = "") async {
        guard pets.isEmpty, !isLoading else { return }
        await reload(query: query)
    }

    func reload(query: String? = nil) async {
        let normalizedQuery = Self.normalized(query ?? self.query)
        let currentRequestID = UUID()
        requestID = currentRequestID
        self.query = normalizedQuery
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        pets = []
        page = 0
        total = 0
        totalPages = 1
        do {
            let result = try await fetch(page: 1, query: normalizedQuery)
            guard requestID == currentRequestID else { return }
            apply(result)
        } catch {
            guard requestID == currentRequestID else { return }
            if !(error is CancellationError) {
                errorMessage = "Couldn’t load codex-pets.net: \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    func loadNextPage() async {
        guard !isLoading, !isLoadingMore, page < totalPages else { return }
        let currentRequestID = requestID
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }
        do {
            let result = try await fetch(page: page + 1, query: query)
            guard requestID == currentRequestID else { return }
            var knownIDs = Set(pets.map(\.id))
            pets.append(contentsOf: result.pets.filter { knownIDs.insert($0.id).inserted })
            page = result.page
            total = result.total
            totalPages = result.totalPages
        } catch {
            guard requestID == currentRequestID, !(error is CancellationError) else { return }
            errorMessage = "Couldn’t load more pets: \(error.localizedDescription)"
        }
    }

    static func requestURL(page: Int, query: String) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/pets"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: "60")
        ]
        let normalizedQuery = normalized(query)
        if !normalizedQuery.isEmpty {
            items.append(URLQueryItem(name: "q", value: normalizedQuery))
        }
        components.queryItems = items
        return components.url!
    }

    private func fetch(page: Int, query: String) async throws -> CodexPetsPage {
        let (data, response) = try await session.data(from: Self.requestURL(page: page, query: query))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CodexPetsPage.self, from: data)
    }

    private func apply(_ result: CodexPetsPage) {
        pets = result.pets
        page = result.page
        total = result.total
        totalPages = result.totalPages
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func download(_ pet: CodexPetSummary, into store: BrowserPetStore) async {
        guard !downloadingPetIDs.contains(pet.id) else { return }
        guard let url = URL(string: pet.spritesheetUrl) else {
            errorMessage = "This pet has no downloadable spritesheet."
            return
        }
        downloadingPetIDs.insert(pet.id)
        defer { downloadingPetIDs.remove(pet.id) }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try store.installPet(pet.installable, spritesheetData: data)
            store.applyPet(pet.id)
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}

struct CodexPetGallerySheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = CodexPetCatalog()
    @State private var query = ""

    let petStore: BrowserPetStore

    var body: some View {
        NavigationStack {
            Group {
                if catalog.isLoading, catalog.pets.isEmpty {
                    ProgressView("Loading pets…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = catalog.errorMessage, catalog.pets.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t Load Pets", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await catalog.reload() } }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
                    }
                } else {
                    galleryGrid
                }
            }
            .navigationTitle("Codex Pets")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search pets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await catalog.reload(query: query) }
                    }
                    .disabled(catalog.isLoading)
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await catalog.reload(query: query)
        }
    }

    private var galleryGrid: some View {
        ScrollView {
            if let errorMessage = catalog.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 12)], spacing: 12) {
                ForEach(catalog.pets) { pet in
                    petCard(pet)
                        .task {
                            if pet.id == catalog.pets.last?.id {
                                await catalog.loadNextPage()
                            }
                        }
                }
            }
            .padding(16)

            if catalog.isLoadingMore {
                ProgressView("Loading more…")
                    .controlSize(.small)
                    .padding(.bottom, 20)
            } else if !catalog.pets.isEmpty {
                Text("\(catalog.pets.count) of \(catalog.total) pets")
                    .font(.caption)
                    .foregroundStyle(theme.mutedLabel)
                    .padding(.bottom, 20)
            }
        }
        .background(theme.background)
    }

    private func petCard(_ pet: CodexPetSummary) -> some View {
        let installed = petStore.installedPets.contains(where: { $0.id == pet.id })
        let active = petStore.selectedPetID == pet.id
        let downloading = catalog.downloadingPetIDs.contains(pet.id)

        return VStack(spacing: 8) {
            Group {
                if let poster = pet.posterUrl.flatMap(URL.init(string:)) {
                    AsyncImage(url: poster) { phase in
                        switch phase {
                        case .success(let image):
                            // Pixel art: nearest-neighbor scaling keeps the
                            // sprite crisp at card size.
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "pawprint")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(theme.mutedLabel)
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Image(systemName: "pawprint")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(theme.mutedLabel)
                }
            }
            .frame(height: 108)
            .frame(maxWidth: .infinity)

            Text(pet.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Button {
                if installed {
                    petStore.applyPet(active ? nil : pet.id)
                } else {
                    Task { await catalog.download(pet, into: petStore) }
                }
            } label: {
                Group {
                    if downloading {
                        ProgressView().controlSize(.mini)
                    } else if active {
                        Label("In use", systemImage: "checkmark")
                    } else if installed {
                        Text("Use")
                    } else {
                        Label("Get", systemImage: "arrow.down.circle")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.bordered)
            .tint(active ? theme.tailnet : theme.accent)
            .disabled(downloading)
        }
        .padding(10)
        .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(active ? theme.tailnet : theme.border, lineWidth: active ? 1 : 0.75)
        }
    }
}
