import CoreGraphics
import Foundation
import Observation
import UIKit

enum PetAnimationState: String, CaseIterable {
    case idle
    case runningRight
    case runningLeft
    case waving
    /// Row 4 — a short celebratory hop. Played once after a slow page load
    /// finally finishes, or when a download completes.
    case jumping
    /// Row 5 — a discouraged reaction. Played once when a page fails to load.
    case failed
    /// Row 6 — an expectant loop. Shown continuously while the active page
    /// is loading.
    case waiting
    case running
    /// Row 8 — absorbing a scrap. Played once when the user saves a
    /// selection or page link to their scrap list.
    case review

    var row: Int {
        switch self {
        case .idle:
            0
        case .runningRight:
            1
        case .runningLeft:
            2
        case .waving:
            3
        case .jumping:
            4
        case .failed:
            5
        case .waiting:
            6
        case .running:
            7
        case .review:
            8
        }
    }

    var frameCount: Int {
        switch self {
        case .idle, .running:
            6
        case .runningRight, .runningLeft:
            8
        case .waving:
            4
        case .jumping:
            5
        case .failed:
            8
        case .waiting, .review:
            6
        }
    }

    var frameDuration: TimeInterval {
        switch self {
        case .idle:
            0.88
        case .runningRight, .runningLeft:
            0.13
        case .waving:
            0.18
        case .running:
            0.16
        case .jumping, .failed:
            0.14
        case .waiting, .review:
            0.15
        }
    }

    /// States every bundled/downloaded atlas is assumed to have real art
    /// for — the classic 5-row layout every pet ships with at minimum.
    static let baseStates: Set<PetAnimationState> = [.idle, .runningRight, .runningLeft, .waving, .running]

    /// The four rows a pet only has if it opts in (bundled pets via
    /// `pet.json`'s `eventAnimations`, downloaded pets by having enough
    /// rows in their grid). Order matches row index.
    static let eventStates: [PetAnimationState] = [.jumping, .failed, .waiting, .review]
}

/// A browser happening the pet reacts to. See `BrowserPetStore.notify(_:)`.
enum PetBrowserEvent {
    /// A page finished loading. `wasSlow` is true when it took long enough
    /// that a little celebration is worth showing (see the pet overlay's
    /// slow-load threshold) — fast loads are common and shouldn't be noisy.
    case pageLoadFinished(wasSlow: Bool)
    /// Navigation failed (not a bad address typed by the user — that never
    /// starts a load in the first place).
    case pageLoadFailed
    /// A download finished successfully.
    case downloadCompleted
    /// The user saved a scrap (selection or page link).
    case scrapSaved
}

/// Special keys the pet can feed into the focused SSH terminal — the keys an
/// iOS software keyboard doesn't offer but tmux/vim users constantly need.
enum TerminalKeystroke: String, Codable, CaseIterable, Identifiable, Sendable {
    case escape
    case tab
    case enter
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    var id: String { rawValue }

    var bytes: [UInt8] {
        switch self {
        case .escape: [0x1B]
        case .tab: [0x09]
        case .enter: [0x0D]
        case .ctrlC: [0x03]
        case .ctrlD: [0x04]
        case .ctrlZ: [0x1A]
        case .ctrlL: [0x0C]
        case .arrowUp: [0x1B, 0x5B, 0x41]
        case .arrowDown: [0x1B, 0x5B, 0x42]
        case .arrowRight: [0x1B, 0x5B, 0x43]
        case .arrowLeft: [0x1B, 0x5B, 0x44]
        }
    }

    var label: String {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .enter: "Return"
        case .ctrlC: "Ctrl+C"
        case .ctrlD: "Ctrl+D"
        case .ctrlZ: "Ctrl+Z"
        case .ctrlL: "Ctrl+L"
        case .arrowUp: "Arrow up"
        case .arrowDown: "Arrow down"
        case .arrowLeft: "Arrow left"
        case .arrowRight: "Arrow right"
        }
    }

    var systemImage: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .enter: "return"
        case .ctrlC, .ctrlD, .ctrlZ, .ctrlL: "control"
        case .arrowUp: "arrow.up"
        case .arrowDown: "arrow.down"
        case .arrowLeft: "arrow.left"
        case .arrowRight: "arrow.right"
        }
    }
}

/// One configurable slot in the pet's quick-action dock.
enum PetQuickAction: Hashable, Identifiable, Sendable {
    case reload
    case newTab
    case goBack
    case goForward
    case openAI
    case toggleTerminal
    case toggleSplit
    case commandPalette
    case copyPageURL
    case pasteAndGo
    case saveScrap
    case sendKey(TerminalKeystroke)

    static let defaults: [PetQuickAction] = [.reload, .newTab, .openAI, .saveScrap]
    static let maxSlots = 4

    static var allOptions: [PetQuickAction] {
        [
            .reload, .newTab, .goBack, .goForward, .openAI,
            .toggleTerminal, .toggleSplit, .commandPalette,
            .copyPageURL, .pasteAndGo, .saveScrap
        ] + TerminalKeystroke.allCases.map(PetQuickAction.sendKey)
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reload: "Reload"
        case .newTab: "New tab"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .openAI: "AI assistant"
        case .toggleTerminal: "SSH terminal"
        case .toggleSplit: "Split view"
        case .commandPalette: "Command palette"
        case .copyPageURL: "Copy page link"
        case .pasteAndGo: "Paste and go"
        case .saveScrap: "Save scrap"
        case .sendKey(let keystroke): "Key · \(keystroke.label)"
        }
    }

    var systemImage: String {
        switch self {
        case .reload: "arrow.clockwise"
        case .newTab: "plus"
        case .goBack: "chevron.backward"
        case .goForward: "chevron.forward"
        case .openAI: "sparkles"
        case .toggleTerminal: "terminal"
        case .toggleSplit: "rectangle.split.2x1"
        case .commandPalette: "command"
        case .copyPageURL: "link"
        case .pasteAndGo: "doc.on.clipboard"
        case .saveScrap: "bookmark"
        case .sendKey(let keystroke): keystroke.systemImage
        }
    }
}

extension PetQuickAction: RawRepresentable, Codable {
    init?(rawValue: String) {
        if rawValue.hasPrefix("key:"),
           let keystroke = TerminalKeystroke(rawValue: String(rawValue.dropFirst(4))) {
            self = .sendKey(keystroke)
            return
        }
        switch rawValue {
        case "reload": self = .reload
        case "newTab": self = .newTab
        case "goBack": self = .goBack
        case "goForward": self = .goForward
        case "openAI": self = .openAI
        case "toggleTerminal": self = .toggleTerminal
        case "toggleSplit": self = .toggleSplit
        case "commandPalette": self = .commandPalette
        case "copyPageURL": self = .copyPageURL
        case "pasteAndGo": self = .pasteAndGo
        case "saveScrap": self = .saveScrap
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .reload: "reload"
        case .newTab: "newTab"
        case .goBack: "goBack"
        case .goForward: "goForward"
        case .openAI: "openAI"
        case .toggleTerminal: "toggleTerminal"
        case .toggleSplit: "toggleSplit"
        case .commandPalette: "commandPalette"
        case .copyPageURL: "copyPageURL"
        case .pasteAndGo: "pasteAndGo"
        case .saveScrap: "saveScrap"
        case .sendKey(let keystroke): "key:\(keystroke.rawValue)"
        }
    }
}

struct PetPosition: Codable, Equatable {
    var x: Double
    var y: Double

    static let defaultPosition = PetPosition(x: 0.06, y: 0.9)

    func clamped() -> PetPosition {
        PetPosition(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

struct BrowserPetSnapshot: Codable, Equatable {
    var scale: Double
    var position: PetPosition
    var quickActions: [PetQuickAction]?
    var selectedPetID: String?
}

/// A pet downloaded from codex-pets.net, stored on disk next to its
/// spritesheet as metadata.json.
struct InstalledCodexPet: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var columns: Int
    var rows: Int

    static let spritesheetFileName = "spritesheet.webp"
    static let metadataFileName = "metadata.json"
}

/// What the sprite renderer needs to draw the active pet.
struct ActivePetAtlas {
    static let bundledKey = "bundled.reto"

    let key: String
    let columns: Int
    let rows: Int
    let image: CGImage?
    /// States this specific atlas has real art for. Always a superset of
    /// `PetAnimationState.baseStates` — the event rows (jumping, failed,
    /// waiting, review) are opt-in per pet. Requesting an unsupported state
    /// falls back to idle rather than showing a blank or out-of-range frame.
    var availableStates: Set<PetAnimationState> = PetAnimationState.baseStates
}

/// Metadata read from a bundled pet's `pet.json` — the same on-disk shape
/// pet-for-safari uses, so pets can be dropped into `Resources/Pets/<id>/`
/// without any code changes beyond the shared atlas contract below.
///
/// `eventAnimations` is an optional extension to that shared shape: the
/// rawValues of whichever `PetAnimationState.eventStates` this pet's atlas
/// has real frames for (e.g. `["jumping", "failed", "waiting", "review"]`).
/// Every bundled atlas is physically sized to 9 rows for layout consistency,
/// but a pet that never authored art for rows 4-8
/// must not claim those rows — hence this is explicit metadata, not just a
/// row-count check.
private struct BundledPetMetadata: Codable {
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String
    let eventAnimations: [String]?
}

/// A pet shipped inside the app bundle (as opposed to one the user downloaded
/// at runtime into `installedPets`). Every bundled pet is expected to follow
/// the shared "codex-pets" 8-column x 9-row atlas contract, matching
/// `PetAnimationState.row`.
struct BundledPet: Identifiable, Equatable, Sendable {
    static let atlasColumns = 8
    static let atlasRows = 9

    let id: String
    let displayName: String
    let description: String
    let columns: Int
    let rows: Int
    let eventAnimationStates: Set<PetAnimationState>
    fileprivate let spritesheetURL: URL
}

extension ActivePetAtlas: Equatable {
    static func == (lhs: ActivePetAtlas, rhs: ActivePetAtlas) -> Bool {
        lhs.key == rhs.key
    }
}

enum BrowserPetSheetDestination: String, Identifiable {
    case settings
    case scraps

    var id: String { rawValue }
}

/// A short line the pet says in a speech bubble. Text is sanitized — control
/// characters become spaces and the length is capped — and the display
/// duration is clamped so a remote event can never pin a bubble forever.
struct PetMessage: Equatable, Identifiable, Sendable {
    static let displayDurationRange: ClosedRange<TimeInterval> = 2...12
    static let defaultDisplayDuration: TimeInterval = 5
    static let maxTextLength = 140

    let id: UUID
    let text: String
    let duration: TimeInterval
    /// Terminal tab the message came from; tapping the bubble focuses it.
    let sourceTerminalTabID: UUID?

    init?(
        text: String,
        duration: TimeInterval = Self.defaultDisplayDuration,
        sourceTerminalTabID: UUID? = nil
    ) {
        let sanitized = Self.sanitize(text)
        guard !sanitized.isEmpty else { return nil }
        id = UUID()
        self.text = sanitized
        self.duration = min(
            max(duration, Self.displayDurationRange.lowerBound),
            Self.displayDurationRange.upperBound
        )
        self.sourceTerminalTabID = sourceTerminalTabID
    }

    static func sanitize(_ text: String) -> String {
        var cleaned = String(
            text.map { character -> Character in
                let isControl = character.unicodeScalars.allSatisfy {
                    CharacterSet.controlCharacters.contains($0)
                }
                return character.isNewline || isControl ? " " : character
            }
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxTextLength {
            cleaned = String(cleaned.prefix(maxTextLength - 1)) + "…"
        }
        return cleaned
    }
}

@MainActor
@Observable
final class BrowserPetStore {
    static let defaultStorageKey = "reto-browser.pet.v1"
    static let scaleRange = 0.6...1.5

    var scale: Double
    var position: PetPosition
    var quickActions: [PetQuickAction]
    var selectedPetID: String?
    var installedPets: [InstalledCodexPet] = []
    var quickActionsVisible = false
    var animationState: PetAnimationState = .idle
    var presentedSheet: BrowserPetSheetDestination?
    var activeMessage: PetMessage?

    static let messageQueueLimit = 5

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let petsDirectory: URL
    @ObservationIgnored private var animationResetTask: Task<Void, Never>?
    @ObservationIgnored private var atlasImageCache: [String: CGImage] = [:]
    @ObservationIgnored private var bundledAtlasImageCache: [String: CGImage] = [:]
    @ObservationIgnored private var messageQueue: [PetMessage] = []
    @ObservationIgnored private var messageDismissTask: Task<Void, Never>?

    /// Every pet bundled under `Resources/Pets/<id>/`, discovered at launch
    /// by scanning that folder reference for `pet.json` metadata files —
    /// nothing here is a hardcoded per-pet name, so dropping in a new pet
    /// directory is enough to make it available.
    @ObservationIgnored private static let bundledPetCatalog: [BundledPet] = {
        guard let petsDirectoryURL = Bundle.main.url(forResource: "Pets", withExtension: nil) else {
            return []
        }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: petsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries.compactMap { directoryURL -> BundledPet? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let metadataURL = directoryURL.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(BundledPetMetadata.self, from: data) else {
                return nil
            }
            let eventStates = Set(
                (metadata.eventAnimations ?? []).compactMap(PetAnimationState.init(rawValue:))
                    .filter { PetAnimationState.eventStates.contains($0) }
            )
            return BundledPet(
                id: metadata.id,
                displayName: metadata.displayName,
                description: metadata.description ?? "",
                columns: BundledPet.atlasColumns,
                rows: BundledPet.atlasRows,
                eventAnimationStates: eventStates,
                spritesheetURL: directoryURL.appendingPathComponent(metadata.spritesheetPath)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }()

    /// Reto is the product's bundled default. Older Banana/Ink Wisp
    /// selections migrate to this nil-means-default state during refresh.
    @ObservationIgnored private static let defaultBundledPetID = "reto"

    static var defaultPetsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetoPets", isDirectory: true)
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = BrowserPetStore.defaultStorageKey,
        petsDirectory: URL = BrowserPetStore.defaultPetsDirectory
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.petsDirectory = petsDirectory

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(BrowserPetSnapshot.self, from: data) {
            scale = Self.clampedScale(snapshot.scale)
            position = snapshot.position.clamped()
            quickActions = Self.normalizedActions(snapshot.quickActions ?? PetQuickAction.defaults)
            selectedPetID = snapshot.selectedPetID
        } else {
            scale = 1
            position = .defaultPosition
            quickActions = PetQuickAction.defaults
            selectedPetID = nil
        }

        let migratedLegacyBundledPet = selectedPetID == "banana" || selectedPetID == "ink-wisp"
        if migratedLegacyBundledPet { selectedPetID = nil }
        refreshInstalledPets()
        if migratedLegacyBundledPet { persist() }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-show-sample-pet-actions") {
            quickActionsVisible = true
        }
        // Verification-only hook so a bundled pet other than the default can
        // be selected without a UI affordance — never used in release
        // builds. Example: `-select-bundled-pet reto`.
        if let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "-select-bundled-pet"),
           ProcessInfo.processInfo.arguments.indices.contains(flagIndex + 1) {
            selectedPetID = ProcessInfo.processInfo.arguments[flagIndex + 1]
        }
        #endif
    }

    /// Pets bundled inside the app (as opposed to downloaded ones), sorted
    /// for display. Reto is always the product default.
    var bundledPets: [BundledPet] { Self.bundledPetCatalog }

    /// `selectedPetID` resolved against the same default the atlas lookup
    /// uses, for UI that needs to mark "the active pet" even when nothing
    /// has been explicitly chosen yet.
    var effectiveSelectedPetID: String? {
        selectedPetID ?? Self.defaultBundledPetID
    }

    var activeAtlas: ActivePetAtlas {
        if let selectedPetID {
            if let pet = installedPets.first(where: { $0.id == selectedPetID }) {
                if let image = atlasImage(for: pet) {
                    return ActivePetAtlas(
                        key: pet.id,
                        columns: pet.columns,
                        rows: pet.rows,
                        image: image,
                        availableStates: Self.availableStates(forRows: pet.rows)
                    )
                }
                // The selected pet is installed but its spritesheet failed
                // to decode (corrupt download, unsupported format, etc).
                // Previously this fell through to the default *bundled*
                // pet's atlas — silently swapping in a different pet's art
                // under the user's selection, and (were the default ever
                // changed to a pet with event-row art) potentially claiming
                // jumping/failed/waiting/review support the actually
                // rendered atlas never had. Surface "no art" for this pet
                // instead of masquerading as an unrelated pet.
                return ActivePetAtlas(
                    key: pet.id,
                    columns: pet.columns,
                    rows: pet.rows,
                    image: nil,
                    availableStates: PetAnimationState.baseStates
                )
            }
            if let bundled = Self.bundledPetCatalog.first(where: { $0.id == selectedPetID }),
               let image = bundledAtlasImage(for: bundled) {
                return ActivePetAtlas(
                    key: "bundled.\(bundled.id)",
                    columns: bundled.columns,
                    rows: bundled.rows,
                    image: image,
                    availableStates: PetAnimationState.baseStates.union(bundled.eventAnimationStates)
                )
            }
        }
        if let defaultPet = Self.bundledPetCatalog.first(where: { $0.id == Self.defaultBundledPetID })
            ?? Self.bundledPetCatalog.first,
           let image = bundledAtlasImage(for: defaultPet) {
            return ActivePetAtlas(
                key: ActivePetAtlas.bundledKey,
                columns: defaultPet.columns,
                rows: defaultPet.rows,
                image: image,
                availableStates: PetAnimationState.baseStates.union(defaultPet.eventAnimationStates)
            )
        }
        return ActivePetAtlas(key: ActivePetAtlas.bundledKey, columns: 8, rows: 9, image: nil)
    }

    /// Downloaded pets carry no explicit per-row art manifest — only a grid
    /// size — so availability is inferred from whether the row physically
    /// exists in the declared grid. `PetAnimationState.row` gives the 0-based
    /// row index each event state needs.
    private static func availableStates(forRows rows: Int) -> Set<PetAnimationState> {
        PetAnimationState.baseStates.union(PetAnimationState.eventStates.filter { $0.row < rows })
    }

    /// True when the active pet's atlas has real art for `state` — event
    /// states (jumping/failed/waiting/review) are opt-in per pet.
    func supports(_ state: PetAnimationState) -> Bool {
        activeAtlas.availableStates.contains(state)
    }

    /// The atlas for a bundled pet by id, regardless of what's currently
    /// selected — used to render preview thumbnails in the pet picker.
    func previewAtlas(forBundledID id: String) -> ActivePetAtlas? {
        guard let bundled = Self.bundledPetCatalog.first(where: { $0.id == id }),
              let image = bundledAtlasImage(for: bundled) else {
            return nil
        }
        return ActivePetAtlas(
            key: "bundled.\(bundled.id)",
            columns: bundled.columns,
            rows: bundled.rows,
            image: image,
            availableStates: PetAnimationState.baseStates.union(bundled.eventAnimationStates)
        )
    }

    /// The atlas for a downloaded/installed pet, regardless of selection —
    /// same purpose as `previewAtlas(forBundledID:)`.
    func previewAtlas(forInstalled pet: InstalledCodexPet) -> ActivePetAtlas? {
        guard let image = atlasImage(for: pet) else { return nil }
        return ActivePetAtlas(
            key: pet.id,
            columns: pet.columns,
            rows: pet.rows,
            image: image,
            availableStates: Self.availableStates(forRows: pet.rows)
        )
    }

    /// `state` if the active pet's atlas has art for it, otherwise `.idle`.
    /// Every animation the pet plays should be routed through this so a pet
    /// missing a row never shows a blank frame.
    func resolvedAnimation(_ state: PetAnimationState) -> PetAnimationState {
        supports(state) ? state : .idle
    }

    func toggleQuickActions() {
        quickActionsVisible.toggle()
        if quickActionsVisible {
            playWave()
        }
    }

    func dismissQuickActions() {
        quickActionsVisible = false
    }

    func setScale(_ value: Double) {
        scale = Self.clampedScale(value)
        persist()
    }

    func setPosition(_ value: PetPosition) {
        position = value.clamped()
        persist()
    }

    func resetPosition() {
        position = .defaultPosition
        persist()
    }

    func quickAction(at index: Int) -> PetQuickAction? {
        quickActions.indices.contains(index) ? quickActions[index] : nil
    }

    /// Sets the action for a dock slot; nil clears the slot. The dock keeps
    /// at least one action so the pet always does something.
    func setQuickAction(_ action: PetQuickAction?, at index: Int) {
        var slots: [PetQuickAction?] = quickActions
        while slots.count < PetQuickAction.maxSlots { slots.append(nil) }
        guard slots.indices.contains(index) else { return }
        slots[index] = action
        let normalized = Self.normalizedActions(slots.compactMap { $0 })
        quickActions = normalized.isEmpty ? [.reload] : normalized
        persist()
    }

    func playWave() {
        playTransient(.waving, for: .milliseconds(760))
    }

    /// Plays `state` once, then returns to idle. No-ops silently (stays on
    /// whatever is currently playing) when the active pet's atlas has no art
    /// for that state — see `resolvedAnimation`.
    private func playTransient(_ state: PetAnimationState, for duration: Duration) {
        guard supports(state) else { return }
        animationResetTask?.cancel()
        animationState = state
        animationResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.animationState = .idle
        }
    }

    // MARK: - Browser event reactions

    /// A browser-level happening the pet can react to. Fired from the pet
    /// overlay's existing observation of session/download state, plus
    /// direct call sites like the scrap-saving action.
    func notify(_ event: PetBrowserEvent) {
        switch event {
        case .pageLoadFinished(let wasSlow):
            guard wasSlow else { return }
            playTransient(.jumping, for: .milliseconds(900))
        case .pageLoadFailed:
            playTransient(.failed, for: .milliseconds(1120))
        case .downloadCompleted:
            playTransient(.jumping, for: .milliseconds(900))
        case .scrapSaved:
            playTransient(.review, for: .milliseconds(900))
        }
    }

    // MARK: - Messages

    /// Waves and shows a speech bubble. Returns false when the text sanitizes
    /// down to nothing (the message is dropped, not an error).
    @discardableResult
    func showMessage(
        _ text: String,
        duration: TimeInterval = PetMessage.defaultDisplayDuration,
        sourceTerminalTabID: UUID? = nil
    ) -> Bool {
        guard let message = PetMessage(
            text: text,
            duration: duration,
            sourceTerminalTabID: sourceTerminalTabID
        ) else {
            return false
        }
        enqueueMessage(message)
        return true
    }

    func enqueueMessage(_ message: PetMessage) {
        guard activeMessage != nil else {
            display(message)
            return
        }
        messageQueue.append(message)
        if messageQueue.count > Self.messageQueueLimit {
            messageQueue.removeFirst(messageQueue.count - Self.messageQueueLimit)
        }
    }

    /// Hides the current bubble and shows the next queued message, if any.
    func dismissActiveMessage() {
        messageDismissTask?.cancel()
        messageDismissTask = nil
        activeMessage = nil
        if !messageQueue.isEmpty {
            display(messageQueue.removeFirst())
        }
    }

    var queuedMessageCount: Int { messageQueue.count }

    private func display(_ message: PetMessage) {
        activeMessage = message
        playWave()
        messageDismissTask?.cancel()
        messageDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(message.duration))
            guard !Task.isCancelled else { return }
            self?.dismissActiveMessage()
        }
    }

    // MARK: - Downloaded pets

    func refreshInstalledPets() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: petsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            installedPets = []
            return
        }
        installedPets = entries.compactMap { directory in
            let metadataURL = directory.appendingPathComponent(InstalledCodexPet.metadataFileName)
            guard let data = try? Data(contentsOf: metadataURL),
                  let pet = try? JSONDecoder().decode(InstalledCodexPet.self, from: data) else {
                return nil
            }
            return pet
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if let selectedPetID,
           !installedPets.contains(where: { $0.id == selectedPetID }),
           !Self.bundledPetCatalog.contains(where: { $0.id == selectedPetID }) {
            self.selectedPetID = nil
        }
    }

    func installPet(_ pet: InstalledCodexPet, spritesheetData: Data) throws {
        let directory = petsDirectory.appendingPathComponent(pet.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try spritesheetData.write(
            to: directory.appendingPathComponent(InstalledCodexPet.spritesheetFileName),
            options: .atomic
        )
        try JSONEncoder().encode(pet).write(
            to: directory.appendingPathComponent(InstalledCodexPet.metadataFileName),
            options: .atomic
        )
        atlasImageCache.removeValue(forKey: pet.id)
        refreshInstalledPets()
    }

    func deletePet(_ petID: String) {
        try? FileManager.default.removeItem(
            at: petsDirectory.appendingPathComponent(petID, isDirectory: true)
        )
        atlasImageCache.removeValue(forKey: petID)
        if selectedPetID == petID { selectedPetID = nil }
        refreshInstalledPets()
        persist()
    }

    func applyPet(_ petID: String?) {
        selectedPetID = petID
        persist()
        playWave()
    }

    private func atlasImage(for pet: InstalledCodexPet) -> CGImage? {
        if let cached = atlasImageCache[pet.id] { return cached }
        let url = petsDirectory
            .appendingPathComponent(pet.id, isDirectory: true)
            .appendingPathComponent(InstalledCodexPet.spritesheetFileName)
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        atlasImageCache[pet.id] = image
        return image
    }

    private func bundledAtlasImage(for pet: BundledPet) -> CGImage? {
        if let cached = bundledAtlasImageCache[pet.id] { return cached }
        guard let image = UIImage(contentsOfFile: pet.spritesheetURL.path)?.cgImage else { return nil }
        bundledAtlasImageCache[pet.id] = image
        return image
    }

    private static func normalizedActions(_ actions: [PetQuickAction]) -> [PetQuickAction] {
        var seen = Set<PetQuickAction>()
        return actions.filter { seen.insert($0).inserted }.prefix(PetQuickAction.maxSlots).map { $0 }
    }

    private static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    private func persist() {
        let snapshot = BrowserPetSnapshot(
            scale: scale,
            position: position,
            quickActions: quickActions,
            selectedPetID: selectedPetID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
