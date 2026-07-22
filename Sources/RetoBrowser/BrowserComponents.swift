import SwiftUI

struct CompactIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(selected ? Color.accentColor : nil)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
