import SwiftUI

enum BrowserFeatureFlags {
    /// The pet is a headline feature. Pro gating (IAP) comes later — not now.
    static let petEnabled = true
}

struct CompactIconButton: View {
    @Environment(BrowserTheme.self) private var theme

    let systemName: String
    let accessibilityLabel: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(selected ? theme.background : theme.label)
                .background(selected ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}
