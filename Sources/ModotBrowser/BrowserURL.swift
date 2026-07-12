import Foundation

enum BrowserURL {
    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if let directURL = URL(string: trimmed),
           let scheme = directURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           directURL.host != nil {
            return directURL
        }

        if looksLikeHost(trimmed),
           let hostURL = URL(string: "https://\(trimmed)"),
           hostURL.host != nil {
            return hostURL
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private static func looksLikeHost(_ value: String) -> Bool {
        !value.contains(where: \Character.isWhitespace) &&
            (value.contains(".") || value == "localhost" || value.hasPrefix("localhost:"))
    }
}

