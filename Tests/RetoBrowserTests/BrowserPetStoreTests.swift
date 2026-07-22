import UIKit
import XCTest
@testable import RetoBrowser

@MainActor
final class BrowserPetStoreTests: XCTestCase {
    func testScaleIsClamped() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setScale(0.1)
        XCTAssertEqual(store.scale, BrowserPetStore.scaleRange.lowerBound)

        store.setScale(3)
        XCTAssertEqual(store.scale, BrowserPetStore.scaleRange.upperBound)
    }

    func testPositionIsClampedAndPersisted() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setPosition(PetPosition(x: -1, y: 2))

        let restored = BrowserPetStore(defaults: defaults, storageKey: "pet-test")
        XCTAssertEqual(restored.position, PetPosition(x: 0, y: 1))
    }

    func testAtlasStateRowsMatchRemotePetContract() {
        XCTAssertEqual(PetAnimationState.idle.row, 0)
        XCTAssertEqual(PetAnimationState.runningRight.row, 1)
        XCTAssertEqual(PetAnimationState.runningLeft.row, 2)
        XCTAssertEqual(PetAnimationState.waving.row, 3)
        XCTAssertEqual(PetAnimationState.jumping.row, 4)
        XCTAssertEqual(PetAnimationState.failed.row, 5)
        XCTAssertEqual(PetAnimationState.waiting.row, 6)
        XCTAssertEqual(PetAnimationState.running.row, 7)
        XCTAssertEqual(PetAnimationState.review.row, 8)
    }

    // MARK: - Event animation availability (C3.2)

    func testResolvedAnimationFallsBackToIdleWhenInstalledPetLacksTheRow() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A 4-row atlas (idle/runningRight/runningLeft/waving, rows 0-3) has
        // no physical row for jumping (4), failed (5), waiting (6), or
        // review (8) — same shape as the bundled Banana sample. Rows are
        // gated by `row < rows` (see testResolvedAnimationRespectsPartialRowCounts),
        // so 5 rows would already reach jumping's row (4) — it takes 4 rows
        // to exclude every event state.
        let pet = InstalledCodexPet(id: "four-row", displayName: "Four Row", columns: 8, rows: 4)
        try store.installPet(pet, spritesheetData: validSpritesheetData(columns: pet.columns, rows: pet.rows))
        store.applyPet(pet.id)

        XCTAssertEqual(store.resolvedAnimation(.jumping), .idle)
        XCTAssertEqual(store.resolvedAnimation(.failed), .idle)
        XCTAssertEqual(store.resolvedAnimation(.waiting), .idle)
        XCTAssertEqual(store.resolvedAnimation(.review), .idle)
        // The base states are never affected by row-count gating.
        XCTAssertEqual(store.resolvedAnimation(.idle), .idle)
        XCTAssertEqual(store.resolvedAnimation(.waving), .waving)
    }

    func testResolvedAnimationPassesThroughWhenInstalledPetHasEnoughRows() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pet = InstalledCodexPet(id: "nine-row", displayName: "Nine Row", columns: 8, rows: 9)
        try store.installPet(pet, spritesheetData: validSpritesheetData(columns: pet.columns, rows: pet.rows))
        store.applyPet(pet.id)

        XCTAssertEqual(store.resolvedAnimation(.jumping), .jumping)
        XCTAssertEqual(store.resolvedAnimation(.failed), .failed)
        XCTAssertEqual(store.resolvedAnimation(.waiting), .waiting)
        XCTAssertEqual(store.resolvedAnimation(.review), .review)
    }

    func testResolvedAnimationRespectsPartialRowCounts() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 6 rows reaches jumping (row 4) and failed (row 5) but not
        // waiting (row 6) or review (row 8).
        let pet = InstalledCodexPet(id: "six-row", displayName: "Six Row", columns: 8, rows: 6)
        try store.installPet(pet, spritesheetData: validSpritesheetData(columns: pet.columns, rows: pet.rows))
        store.applyPet(pet.id)

        XCTAssertEqual(store.resolvedAnimation(.jumping), .jumping)
        XCTAssertEqual(store.resolvedAnimation(.failed), .failed)
        XCTAssertEqual(store.resolvedAnimation(.waiting), .idle)
        XCTAssertEqual(store.resolvedAnimation(.review), .idle)
    }

    func testNotifyPlaysTheMatchingTransientAnimationWhenSupported() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pet = InstalledCodexPet(id: "nine-row-2", displayName: "Nine Row", columns: 8, rows: 9)
        try store.installPet(pet, spritesheetData: validSpritesheetData(columns: pet.columns, rows: pet.rows))
        store.applyPet(pet.id)

        store.notify(.pageLoadFailed)
        XCTAssertEqual(store.animationState, .failed)

        store.notify(.scrapSaved)
        XCTAssertEqual(store.animationState, .review)

        store.notify(.downloadCompleted)
        XCTAssertEqual(store.animationState, .jumping)
    }

    func testNotifyIgnoresFastPageLoadsAndUnsupportedRows() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pet = InstalledCodexPet(id: "four-row-2", displayName: "Four Row", columns: 8, rows: 4)
        try store.installPet(pet, spritesheetData: validSpritesheetData(columns: pet.columns, rows: pet.rows))
        // Select the pet directly rather than via `applyPet`, which also
        // plays a wave transient that only resets to `.idle` asynchronously
        // (after a 760ms Task.sleep) — asserting `.idle` right after would
        // otherwise observe that leftover wave instead of exercising the
        // `notify` behavior this test is actually about.
        store.selectedPetID = pet.id

        store.notify(.pageLoadFinished(wasSlow: false))
        XCTAssertEqual(store.animationState, .idle)

        // A slow-load celebration would be `.jumping`, but this pet's atlas
        // doesn't have that row — must stay idle, not go out of range.
        store.notify(.pageLoadFinished(wasSlow: true))
        XCTAssertEqual(store.animationState, .idle)
    }

    func testQuickActionsPersistAndDeduplicate() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setQuickAction(.sendKey(.ctrlC), at: 0)
        store.setQuickAction(.pasteAndGo, at: 1)
        store.setQuickAction(.pasteAndGo, at: 2)

        XCTAssertEqual(store.quickActions.filter { $0 == .pasteAndGo }.count, 1)

        let restored = BrowserPetStore(
            defaults: defaults,
            storageKey: "pet-test",
            petsDirectory: temporaryPetsDirectory()
        )
        XCTAssertEqual(restored.quickActions.first, .sendKey(.ctrlC))
    }

    func testClearingEverySlotKeepsOneAction() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 0..<PetQuickAction.maxSlots {
            store.setQuickAction(nil, at: index)
        }

        XCTAssertFalse(store.quickActions.isEmpty)
    }

    func testQuickActionRawValueRoundTripsIncludingKeys() {
        for action in PetQuickAction.allOptions {
            XCTAssertEqual(PetQuickAction(rawValue: action.rawValue), action)
        }
    }

    func testTerminalKeystrokeBytes() {
        XCTAssertEqual(TerminalKeystroke.escape.bytes, [0x1B])
        XCTAssertEqual(TerminalKeystroke.ctrlC.bytes, [0x03])
        XCTAssertEqual(TerminalKeystroke.arrowUp.bytes, [0x1B, 0x5B, 0x41])
        XCTAssertEqual(TerminalKeystroke.arrowLeft.bytes, [0x1B, 0x5B, 0x44])
    }

    func testInstalledPetRoundTripsThroughDiskAndSelection() throws {
        let directory = temporaryPetsDirectory()
        let suiteName = "BrowserPetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BrowserPetStore(defaults: defaults, storageKey: "pet-test", petsDirectory: directory)

        let pet = InstalledCodexPet(id: "niumou", displayName: "牛哞", columns: 8, rows: 11)
        try store.installPet(pet, spritesheetData: Data([0x0]))
        store.applyPet(pet.id)

        XCTAssertEqual(store.installedPets.map(\.id), ["niumou"])
        XCTAssertEqual(store.selectedPetID, "niumou")

        let restored = BrowserPetStore(defaults: defaults, storageKey: "pet-test", petsDirectory: directory)
        XCTAssertEqual(restored.selectedPetID, "niumou")
        XCTAssertEqual(restored.installedPets.first?.rows, 11)

        store.deletePet(pet.id)
        XCTAssertNil(store.selectedPetID)
        XCTAssertTrue(store.installedPets.isEmpty)
    }

    func testCodexPetSummaryGridFromValidationReport() throws {
        let json = """
        {"id":"niumou","displayName":"牛哞","spritesheetUrl":"https://codex-pets.net/assets/pets/v/1/niumou/spritesheet.webp",
         "previewUrl":"https://codex-pets.net/assets/pets/v/1/niumou/preview.webp",
         "validationReport":{"atlasSize":"1536x2288","cellSize":"192x208"}}
        """
        let pet = try JSONDecoder().decode(CodexPetSummary.self, from: Data(json.utf8))

        XCTAssertEqual(pet.grid.columns, 8)
        XCTAssertEqual(pet.grid.rows, 11)
        XCTAssertEqual(pet.installable.rows, 11)

        let legacyJSON = """
        {"id":"banana","displayName":"Banana","spritesheetUrl":"https://codex-pets.net/x.webp"}
        """
        let legacy = try JSONDecoder().decode(CodexPetSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.grid.columns, 8)
        XCTAssertEqual(legacy.grid.rows, 9)
    }

    func testCodexPetCatalogRequestUsesServerPaginationAndSearch() throws {
        let url = CodexPetCatalog.requestURL(page: 3, query: "  banana pet  ")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map {
            ($0.name, $0.value)
        })

        XCTAssertEqual(queryItems["page"], "3")
        XCTAssertEqual(queryItems["pageSize"], "60")
        XCTAssertEqual(queryItems["q"], "banana pet")
    }

    func testPetMessageSanitizesControlCharactersAndCapsLength() throws {
        let message = try XCTUnwrap(PetMessage(text: "hi\u{07}\nthere\u{1B}[31m"))
        XCTAssertEqual(message.text, "hi  there [31m")

        let long = try XCTUnwrap(PetMessage(text: String(repeating: "a", count: 500)))
        XCTAssertEqual(long.text.count, PetMessage.maxTextLength)
        XCTAssertTrue(long.text.hasSuffix("…"))
    }

    func testPetMessageDurationIsClamped() throws {
        XCTAssertEqual(
            try XCTUnwrap(PetMessage(text: "hi", duration: 0)).duration,
            PetMessage.displayDurationRange.lowerBound
        )
        XCTAssertEqual(
            try XCTUnwrap(PetMessage(text: "hi", duration: 9_999)).duration,
            PetMessage.displayDurationRange.upperBound
        )
    }

    func testEmptyOrControlOnlyMessagesAreDropped() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(PetMessage(text: "  \u{07}\n "))
        XCTAssertFalse(store.showMessage(" \u{1B} "))
        XCTAssertNil(store.activeMessage)
    }

    func testMessageQueueShowsWavesAndAdvancesInOrder() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(store.showMessage("first"))
        XCTAssertEqual(store.activeMessage?.text, "first")
        XCTAssertEqual(store.animationState, .waving)

        store.showMessage("second")
        XCTAssertEqual(store.activeMessage?.text, "first")
        XCTAssertEqual(store.queuedMessageCount, 1)

        store.dismissActiveMessage()
        XCTAssertEqual(store.activeMessage?.text, "second")

        store.dismissActiveMessage()
        XCTAssertNil(store.activeMessage)
        XCTAssertEqual(store.queuedMessageCount, 0)
    }

    func testMessageQueueDropsOldestBeyondLimit() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.showMessage("active")
        for index in 0..<(BrowserPetStore.messageQueueLimit + 2) {
            store.showMessage("queued \(index)")
        }

        XCTAssertEqual(store.queuedMessageCount, BrowserPetStore.messageQueueLimit)

        store.dismissActiveMessage()
        XCTAssertEqual(store.activeMessage?.text, "queued 2")
    }

    private func makeStore() -> (BrowserPetStore, UserDefaults, String) {
        let suiteName = "BrowserPetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = BrowserPetStore(
            defaults: defaults,
            storageKey: "pet-test",
            petsDirectory: temporaryPetsDirectory()
        )
        return (store, defaults, suiteName)
    }

    private func temporaryPetsDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserPetStoreTests", isDirectory: true)
            .appendingPathComponent(name.hashValue.description, isDirectory: true)
    }

    /// A tiny but genuinely decodable image, sized to the declared grid —
    /// needed wherever a test exercises `activeAtlas`/`resolvedAnimation`,
    /// since those only treat an installed pet as active once its
    /// spritesheet actually decodes. Rendering a real PNG at runtime (rather
    /// than a hand-rolled byte blob) is what makes it reliably decodable.
    private func validSpritesheetData(columns: Int, rows: Int, cellSize: Int = 4) -> Data {
        let size = CGSize(width: columns * cellSize, height: rows * cellSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }
}
