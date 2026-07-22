import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class BrowserTheme {
    let background = Color(uiColor: .systemBackground)
    let raisedBackground = Color(uiColor: .secondarySystemBackground)
    let mutedBackground = Color(uiColor: .tertiarySystemBackground)
    let border = Color(uiColor: .separator)
    let label = Color.primary
    let mutedLabel = Color.secondary
    let accent = Color(uiColor: .label)
    let tailnet = Color(red: 0.06, green: 0.48, blue: 0.34)

    let compactRadius: CGFloat = 8
    let rowHeight: CGFloat = 34
}

/// Resolved appearance for the command bar when it mirrors the page's own
/// background: the tint itself plus the interface style whose system colors
/// stay legible on top of it.
struct PageChromeAppearance: Equatable {
    var tint: Color?
    var colorScheme: ColorScheme?

    static let neutral = PageChromeAppearance(tint: nil, colorScheme: nil)

    /// Perceived brightness decides light vs dark chrome. The 0.6 cut sits
    /// above mid-grey so mid-tone brand colors get white-on-color text, which
    /// stays readable further into the light range than black does.
    static func resolve(_ color: UIColor?) -> PageChromeAppearance {
        guard let color else { return .neutral }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else {
            return .neutral
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return PageChromeAppearance(
            tint: Color(uiColor: color),
            colorScheme: luminance > 0.6 ? .light : .dark
        )
    }
}
