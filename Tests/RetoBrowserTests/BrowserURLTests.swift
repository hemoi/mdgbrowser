import XCTest
@testable import RetoBrowser

final class BrowserURLTests: XCTestCase {
    func testKeepsSecureURL() {
        XCTAssertEqual(
            BrowserURL.resolve("https://developer.apple.com/documentation")?.absoluteString,
            "https://developer.apple.com/documentation"
        )
    }

    func testAddsHTTPSForHostname() {
        XCTAssertEqual(
            BrowserURL.resolve("swift.org")?.absoluteString,
            "https://swift.org"
        )
    }

    func testTurnsPlainTextIntoSearch() {
        let url = BrowserURL.resolve("SwiftUI App Intents")

        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            "SwiftUI App Intents"
        )
    }

    func testKoreanAndCJKSearchTextSurvivesURLEncoding() throws {
        let query = "한글 입력 테스트 中文"
        let url = try XCTUnwrap(BrowserURL.resolve(query))

        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            query
        )
    }

    func testRejectsWhitespaceOnlyInput() {
        XCTAssertNil(BrowserURL.resolve("   \n"))
    }

    @MainActor
    func testOpenWebsiteIntentHandsURLToBrowser() async throws {
        let intent = OpenWebsiteIntent()
        intent.website = "swift.org"

        _ = try await intent.perform()

        XCTAssertEqual(
            BrowserIntentRouter.shared.lastOpenedURL?.absoluteString,
            "https://swift.org"
        )
    }
}
