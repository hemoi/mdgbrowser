import XCTest
@testable import RetoBrowser

final class BrowserScrapTests: XCTestCase {
    func testInitRejectsNonHTTPURLs() {
        XCTAssertNil(BrowserScrap(pageTitle: "t", pageURL: "not a url", selectedText: "x"))
        XCTAssertNil(BrowserScrap(pageTitle: "t", pageURL: "ftp://example.com", selectedText: "x"))
        XCTAssertNotNil(BrowserScrap(pageTitle: "t", pageURL: "https://example.com", selectedText: "x"))
    }

    func testInitTrimsAndClampsFields() throws {
        let longText = String(repeating: "a", count: BrowserScrap.maxSelectedTextLength + 50)
        let scrap = try XCTUnwrap(BrowserScrap(
            pageTitle: "  Title  ",
            pageURL: "https://example.com",
            selectedText: "  \(longText)  "
        ))
        XCTAssertEqual(scrap.pageTitle, "Title")
        XCTAssertEqual(scrap.selectedText.count, BrowserScrap.maxSelectedTextLength)
    }

    func testIsLinkOnlyWhenSelectionEmpty() throws {
        let scrap = try XCTUnwrap(BrowserScrap(pageTitle: "t", pageURL: "https://example.com", selectedText: "   "))
        XCTAssertTrue(scrap.isLinkOnly)

        let withText = try XCTUnwrap(BrowserScrap(pageTitle: "t", pageURL: "https://example.com", selectedText: "hi"))
        XCTAssertFalse(withText.isLinkOnly)
    }
}

final class BrowserScrapStoreTests: XCTestCase {
    func testSaveListDelete() throws {
        let store = BrowserScrapStore(directory: temporaryDirectory())

        let scrap = try XCTUnwrap(
            BrowserScrap(pageTitle: "Example", pageURL: "https://example.com", selectedText: "hello")
        )
        try store.save(scrap)

        XCTAssertEqual(store.list().map(\.id), [scrap.id])

        store.delete(id: scrap.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDuplicateSaveWithinWindowReturnsExistingScrap() throws {
        let store = BrowserScrapStore(directory: temporaryDirectory())

        let first = try XCTUnwrap(
            BrowserScrap(pageTitle: "Example", pageURL: "https://example.com", selectedText: "hello")
        )
        try store.save(first)

        let second = try XCTUnwrap(
            BrowserScrap(pageTitle: "Example", pageURL: "https://example.com", selectedText: "hello")
        )
        let saved = try store.save(second)

        XCTAssertEqual(saved.id, first.id)
        XCTAssertEqual(store.list().count, 1)
    }

    func testDifferentSelectionsOnSamePageAreNotDeduped() throws {
        let store = BrowserScrapStore(directory: temporaryDirectory())

        try store.save(try XCTUnwrap(
            BrowserScrap(pageTitle: "t", pageURL: "https://example.com", selectedText: "one")
        ))
        try store.save(try XCTUnwrap(
            BrowserScrap(pageTitle: "t", pageURL: "https://example.com", selectedText: "two")
        ))

        XCTAssertEqual(store.list().count, 2)
    }

    func testListSortsNewestFirst() throws {
        let store = BrowserScrapStore(directory: temporaryDirectory())

        let older = try XCTUnwrap(BrowserScrap(
            pageTitle: "t", pageURL: "https://example.com", selectedText: "older",
            createdAt: Date(timeIntervalSince1970: 0)
        ))
        let newer = try XCTUnwrap(BrowserScrap(
            pageTitle: "t", pageURL: "https://example.com", selectedText: "newer",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try store.save(older)
        try store.save(newer)

        XCTAssertEqual(store.list().map(\.selectedText), ["newer", "older"])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserScrapStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
