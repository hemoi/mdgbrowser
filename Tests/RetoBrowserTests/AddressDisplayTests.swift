import XCTest
@testable import RetoBrowser

final class AddressDisplayTests: XCTestCase {
    func testDropsHTTPSScheme() {
        let url = URL(string: "https://example.com/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "example.com")
    }

    func testDropsHTTPScheme() {
        let url = URL(string: "http://example.com/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "example.com")
    }

    func testStripsLeadingWWW() {
        let url = URL(string: "https://www.example.com/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "example.com")
    }

    func testKeepsWWWInTheMiddleOfAHost() {
        // Only a *leading* "www." is chrome, not an incidental substring.
        let url = URL(string: "https://wwwexample.com/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "wwwexample.com")
    }

    func testShowsShortPath() {
        let url = URL(string: "https://example.com/docs/intro")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "example.com/docs/intro")
    }

    func testTruncatesLongPaths() {
        let longSegment = String(repeating: "a", count: 60)
        let url = URL(string: "https://example.com/\(longSegment)")!
        let result = AddressDisplay.readingText(for: url)
        XCTAssertTrue(result.hasPrefix("example.com/"))
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThan(result.count, url.path.count)
    }

    func testHidesQueryParameters() {
        let url = URL(string: "https://example.com/search?q=secret&token=abc123")!
        let result = AddressDisplay.readingText(for: url)
        XCTAssertFalse(result.contains("secret"))
        XCTAssertFalse(result.contains("token"))
        XCTAssertFalse(result.contains("?"))
    }

    func testHidesFragments() {
        let url = URL(string: "https://example.com/docs#section-two")!
        let result = AddressDisplay.readingText(for: url)
        XCTAssertFalse(result.contains("#"))
        XCTAssertFalse(result.contains("section-two"))
    }

    func testPunycodeHostIsShownVerbatim() {
        let url = URL(string: "https://xn--fsqu00a.example/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "xn--fsqu00a.example")
    }

    func testSSHSchemeDropsSchemeAndKeepsHost() {
        let url = URL(string: "ssh://user@example.com:2222/")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "example.com")
    }

    func testFileSchemeShowsPathOnly() {
        let url = URL(string: "file:///Users/test/notes.txt")!
        XCTAssertEqual(AddressDisplay.readingText(for: url), "/Users/test/notes.txt")
    }

    func testInternalStartPageWithNilURLReadsEmpty() {
        XCTAssertEqual(AddressDisplay.readingText(for: nil), "")
    }

    func testStartPageURLItselfIsNotSpecialCased() {
        // BrowserSession maps the start page's own URL to a nil currentURL;
        // this function only has to not crash if it's ever handed the URL
        // directly.
        XCTAssertEqual(AddressDisplay.readingText(for: StartPage.url), "start.reto.local")
    }

    func testEditingTextIsLosslessIncludingQueryAndFragment() {
        let url = URL(string: "https://www.example.com/search?q=secret#top")!
        XCTAssertEqual(AddressDisplay.editingText(for: url), url.absoluteString)
    }

    func testEditingTextForNilURLIsEmpty() {
        XCTAssertEqual(AddressDisplay.editingText(for: nil), "")
    }
}
