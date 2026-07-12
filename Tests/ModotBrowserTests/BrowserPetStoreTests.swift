import XCTest
@testable import ModotBrowser

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
        XCTAssertEqual(PetAnimationState.running.row, 7)
    }

    private func makeStore() -> (BrowserPetStore, UserDefaults, String) {
        let suiteName = "BrowserPetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (BrowserPetStore(defaults: defaults, storageKey: "pet-test"), defaults, suiteName)
    }
}
