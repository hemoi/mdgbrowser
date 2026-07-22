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

    /// Fill for a prominent, filled action control (e.g. an empty state's
    /// primary button). Unlike `accent`, which tracks `.label` and therefore
    /// flips to white in dark mode, this stays a saturated color in both
    /// appearances so a fixed-color title drawn on top of it is always
    /// legible. Never derive a filled control's background from `accent`.
    var primaryActionFill: Color { tailnet }
    /// Title color guaranteed to contrast `primaryActionFill` in both
    /// appearances.
    var primaryActionLabel: Color { Color.white }
}

/// Shared style for a prominent filled action button. Routes every
/// "primary action" control through one place so its fill/label pairing
/// can't drift out of contrast the way ad-hoc
/// `.buttonStyle(.borderedProminent).tint(theme.accent)` call sites did.
struct PrimaryActionButtonStyle: ButtonStyle {
    let theme: BrowserTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.primaryActionLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                theme.primaryActionFill.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: theme.compactRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.compactRadius, style: .continuous))
    }
}

extension View {
    /// Applies the app's shared prominent-action look: a saturated fill with
    /// a foreground guaranteed to contrast it in both light and dark.
    func primaryActionStyle(_ theme: BrowserTheme) -> some View {
        buttonStyle(PrimaryActionButtonStyle(theme: theme))
    }
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
