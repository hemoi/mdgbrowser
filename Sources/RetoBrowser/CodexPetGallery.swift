import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

/// One recommended place to find more pet packages, shown in the gallery's
/// "Get more pets" section. Data, not scattered literals, so adding a source
/// later is a one-line change here.
struct PetAcquisitionSource: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL?
    /// True when the destination is known not to resolve yet — shown as
    /// "Coming soon" and not tappable, rather than presented as a working
    /// link. Never mark a real, verified URL as a placeholder or vice versa.
    let isPlaceholder: Bool

    /// Verified 2026-07-23: itch.io's pixel-art tag and OpenGameArt.org both
    /// resolve. reto.dev/pets does not exist yet (404) — listed as a
    /// placeholder rather than a dead link.
    static let recommended: [PetAcquisitionSource] = [
        PetAcquisitionSource(
            id: "itch-io-pixel-art",
            title: "itch.io — pixel art assets",
            subtitle: "Thousands of indie sprite and pixel-art packs, many free.",
            url: URL(string: "https://itch.io/game-assets/tag-pixel-art"),
            isPlaceholder: false
        ),
        PetAcquisitionSource(
            id: "opengameart",
            title: "OpenGameArt.org",
            subtitle: "Free, open-licensed game sprites and animation sheets.",
            url: URL(string: "https://opengameart.org"),
            isPlaceholder: false
        ),
        PetAcquisitionSource(
            id: "reto-pets-page",
            title: "Reto pets page",
            subtitle: "Coming soon — official pet packs from Reto.",
            url: URL(string: "https://reto.dev/pets"),
            isPlaceholder: true
        )
    ]
}

struct CodexPetGallerySheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = CodexPetCatalog()
    @State private var query = ""
    @State private var downloadsPackages: [URL] = []
    @State private var importerPresented = false
    @State private var installError: String?

    let petStore: BrowserPetStore
    /// Opens a URL in a new browser tab — used by "Get more pets" sources.
    var openInBrowser: (URL) -> Void = { _ in }

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
                            .primaryActionStyle(theme)
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
        .onAppear(perform: refreshDownloadsPackages)
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: importerContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImporterResult(result)
        }
        .alert(
            "Couldn’t Install Pet",
            isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })
        ) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    private var importerContentTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        if let retopet = UTType(filenameExtension: "retopet") {
            types.append(retopet)
        }
        return types
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

            acquisitionSection

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

    // MARK: - Get more pets (C3.3)

    private var acquisitionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get more pets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.mutedLabel)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(PetAcquisitionSource.recommended) { source in
                    acquisitionSourceRow(source)
                    if source.id != PetAcquisitionSource.recommended.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            if !downloadsPackages.isEmpty {
                Text("Found in Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.mutedLabel)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(downloadsPackages, id: \.self) { url in
                        downloadedPackageRow(url)
                        if url != downloadsPackages.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }

            Button {
                importerPresented = true
            } label: {
                Label("Import a pet package…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .accessibilityIdentifier("pet.gallery.import")

            Text("A pet package is a folder or .zip (or .retopet) containing pet.json and a spritesheet image.")
                .font(.caption)
                .foregroundStyle(theme.mutedLabel)
                .padding(.horizontal, 16)

            Divider().padding(.top, 4)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func acquisitionSourceRow(_ source: PetAcquisitionSource) -> some View {
        Button {
            guard !source.isPlaceholder, let url = source.url else { return }
            openInBrowser(url)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .foregroundStyle(source.isPlaceholder ? theme.mutedLabel : theme.label)
                    Text(source.subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.mutedLabel)
                }
                Spacer()
                if source.isPlaceholder {
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(theme.mutedLabel)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(theme.mutedLabel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source.isPlaceholder)
    }

    private func downloadedPackageRow(_ url: URL) -> some View {
        HStack {
            Text(url.lastPathComponent)
                .foregroundStyle(theme.label)
                .lineLimit(1)
            Spacer()
            Button("Install") {
                install(from: url)
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func refreshDownloadsPackages() {
        downloadsPackages = PetPackageInstaller.discoverPackages(in: BrowserDownloadManager.downloadsDirectory)
    }

    private func handleImporterResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer { if didAccessScope { url.stopAccessingSecurityScopedResource() } }
            install(from: url)
        case .failure(let error):
            installError = error.localizedDescription
        }
    }

    private func install(from url: URL) {
        do {
            let pet = try PetPackageInstaller.install(from: url, into: petStore)
            petStore.applyPet(pet.id)
            refreshDownloadsPackages()
        } catch {
            installError = error.localizedDescription
        }
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
