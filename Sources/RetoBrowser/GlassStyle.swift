import SwiftUI
import UIKit

/// Design tokens for the island chrome's glass surfaces. Kept in its own
/// file (rather than `BrowserTheme.swift`) because another workstream owns
/// that file concurrently.
enum GlassMetrics {
    /// Corner radius of the rail's bottom edge (the edge that meets the
    /// canvas when collapsed).
    static let railCornerRadius: CGFloat = 18
    /// Corner radius of the expanded surface panel.
    static let surfaceCornerRadius: CGFloat = 22
    /// Corner radius of individual controls inside the surface (the address
    /// field, icon buttons).
    static let controlCornerRadius: CGFloat = 12
    static let hairline: CGFloat = 0.75
}

/// How much a page's own reported background should darken/lighten the
/// glass so labels and icons drawn on top of it stay legible. `.ultraThinMaterial`
/// alone can wash out over pages that sit at the very ends of the luminance
/// range (pure white, pure black); this adds back just enough opacity to
/// recover contrast without losing the glass look on ordinary pages.
enum GlassLegibility {
    static func scrim(for backgroundColor: UIColor?) -> Double {
        guard let backgroundColor else { return 0 }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else {
            return 0
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        if luminance > 0.94 || luminance < 0.06 {
            return 0.16
        }
        return 0
    }
}

/// A translucent, blurred surface with a soft inner highlight and a shadow
/// for depth, tinted to match the page underneath when one is known. Built
/// on the system materials so it adapts to light/dark automatically.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let shape: S
    var appearance: PageChromeAppearance = .neutral
    var scrim: Double = 0

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint = appearance.tint {
                        shape.fill(tint.opacity(0.3))
                    }
                    if scrim > 0 {
                        shape.fill((colorScheme == .dark ? Color.black : Color.white).opacity(scrim))
                    }
                }
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: GlassMetrics.hairline
                    )
                    .blendMode(.plusLighter)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.16), radius: 16, y: 8)
    }
}

extension View {
    func glassSurface<S: InsettableShape>(
        _ shape: S,
        appearance: PageChromeAppearance = .neutral,
        scrim: Double = 0
    ) -> some View {
        modifier(GlassSurface(shape: shape, appearance: appearance, scrim: scrim))
    }
}

/// A small glass icon control shared by the rail and the expanded surface.
struct GlassIconButton: View {
    @Environment(BrowserTheme.self) private var theme

    let systemName: String
    let accessibilityLabel: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                // Selected state deliberately does NOT use
                // `theme.primaryActionFill` (== `theme.tailnet`, brand
                // green) — the browsing chrome must stay green-free. `label`
                // as the fill with `background` as the foreground flips
                // black-on-white/white-on-black automatically in both
                // appearances, the same neutral pairing `AppBarIconButton`
                // already uses in the iPad command bar.
                .foregroundStyle(selected ? theme.background : theme.label)
                .background {
                    if selected {
                        Circle().fill(theme.label)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}
