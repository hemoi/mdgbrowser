import Foundation
import Observation

@MainActor
@Observable
final class BrowserIntentRouter {
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let url: URL
    }

    static let shared = BrowserIntentRouter()

    private(set) var request: Request?
    private(set) var lastOpenedURL: URL?

    private init() {}

    func open(_ url: URL) {
        lastOpenedURL = url
        request = Request(url: url)
    }

    func consumeRequest() -> URL? {
        defer { request = nil }
        return request?.url
    }
}
