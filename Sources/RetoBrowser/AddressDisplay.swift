import Foundation

/// Pure transform from a URL to the two ways the chrome shows an address:
/// a short "reading" form used while the field is not focused, and the
/// exact "editing" form used while it is.
///
/// Reading state deliberately throws information away for legibility
/// (scheme, `www.`, query, fragment); editing state never does — whatever
/// the user copies or edits must be the real URL.
enum AddressDisplay {
    /// Path beyond this many characters is truncated with an ellipsis so a
    /// deep link doesn't stretch the field back out to full width.
    static let maxPathLength = 28

    /// The exact, lossless URL string shown while the address field is
    /// focused for editing. Nothing is dropped: scheme, path, query, and
    /// fragment all survive.
    static func editingText(for url: URL?) -> String {
        url?.absoluteString ?? ""
    }

    /// The shortened string shown while the address field is not focused.
    /// `nil` (the internal start page has no `currentURL`) reads as an
    /// empty field rather than an internal URL.
    static func readingText(for url: URL?) -> String {
        guard let url else { return "" }

        let host = url.host.map(stripWWW) ?? ""
        let path = truncatedPath(url.path)
        let combined = host + path

        // Schemes with neither a host nor a path (essentially none in
        // practice) fall back to the exact string rather than an empty
        // field, so something is always shown.
        return combined.isEmpty ? url.absoluteString : combined
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func truncatedPath(_ path: String) -> String {
        guard path != "/", !path.isEmpty else { return "" }
        guard path.count > maxPathLength else { return path }
        let endIndex = path.index(path.startIndex, offsetBy: maxPathLength)
        return String(path[..<endIndex]) + "…"
    }
}
