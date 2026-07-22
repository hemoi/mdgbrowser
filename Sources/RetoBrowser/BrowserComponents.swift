import SwiftUI

enum BrowserFeatureFlags {
    /// The pet overlay is parked while the browser chrome is being reworked.
    /// Its stores, sprites, and tmux event plumbing stay in the build so it
    /// can be switched back on without reconstruction.
    static let petEnabled = false
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
