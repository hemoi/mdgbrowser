import SwiftUI

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
                .frame(width: 36, height: 36)
                .foregroundStyle(selected ? theme.background : theme.label)
                .background(selected ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ShadcnField: ViewModifier {
    @Environment(BrowserTheme.self) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(theme.background)
            .overlay {
                RoundedRectangle(cornerRadius: theme.compactRadius)
                    .stroke(theme.border, lineWidth: 0.75)
            }
    }
}

extension View {
    func shadcnField() -> some View {
        modifier(ShadcnField())
    }
}
