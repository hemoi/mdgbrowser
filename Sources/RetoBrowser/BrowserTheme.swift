import Observation
import SwiftUI

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

