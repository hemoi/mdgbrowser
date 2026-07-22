import XCTest
@testable import RetoBrowser

@MainActor
final class BrowserAIStoreTests: XCTestCase {
    func testDefaultProviderIsChatGPT() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(store.settings.provider, .chatGPT)
        XCTAssertEqual(store.settings.effectiveURL.host(), "chatgpt.com")
    }

    func testCustomProviderRequiresWebURL() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var invalid = store.settings
        invalid.provider = .custom
        invalid.customURLString = "not a URL"
        XCTAssertFalse(store.saveSettings(invalid))

        invalid.customName = "Local chat"
        invalid.customURLString = "https://chat.example.test/room"
        XCTAssertTrue(store.saveSettings(invalid))
        XCTAssertEqual(store.settings.displayName, "Local chat")
        XCTAssertEqual(store.settings.effectiveURL.host(), "chat.example.test")
    }

    func testProviderSettingsPersist() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = store.settings
        settings.provider = .gemini
        XCTAssertTrue(store.saveSettings(settings))

        let restored = BrowserAIStore(defaults: defaults, storageKey: "ai-test")
        XCTAssertEqual(restored.settings.provider, .gemini)
        XCTAssertEqual(restored.settings.effectiveURL.host(), "gemini.google.com")
    }

    func testCurrentPagePromptIncludesTitleAndURL() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.insertCurrentPage(
            url: URL(string: "https://example.com/docs?lang=ko")!,
            title: "문서"
        )

        XCTAssertEqual(store.prompt, "Review 문서: https://example.com/docs?lang=ko")
    }

    private func makeStore() -> (BrowserAIStore, UserDefaults, String) {
        let suiteName = "BrowserAIStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (BrowserAIStore(defaults: defaults, storageKey: "ai-test"), defaults, suiteName)
    }
}
