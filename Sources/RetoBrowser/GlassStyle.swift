import SwiftUI
import UIKit

/// Design tokens for the island chrome. Kept in its own file (rather than
/// `BrowserTheme.swift`) because another workstream owns that file
/// concurrently.
enum GlassMetrics {
    /// Upper bound for the expanded shell's continuous radius. The actual
    /// value is adjusted by IslandChrome using the device's top safe-area
    /// inset so the shell follows the phone's own corner language.
    static let surfaceCornerRadius: CGFloat = 48
    /// Keeps the expanded shell's top edge visible below the screen edge
    /// while the inline controls remain aligned with the hardware island.
    static let surfaceTopInset: CGFloat = 10
    /// Corner radius of individual controls inside the surface (the address
    /// field, icon buttons).
    static let controlCornerRadius: CGFloat = 17
    /// The address field reads lighter and tighter than the outer island, but
    /// its wrapper remains 44pt tall for a comfortable touch target.
    static let addressVisualHeight: CGFloat = 34
    static let addressHitHeight: CGFloat = 44
    static let hairline: CGFloat = 0.75
}

/// Deliberately small haptic vocabulary for high-value state changes only.
/// UIKit automatically follows the device's System Haptics preference.
@MainActor
enum RetoHaptics {
    static func islandTransition(expanded: Bool) {
        UIImpactFeedbackGenerator(style: expanded ? .light : .soft).impactOccurred(intensity: 0.7)
    }

    static func connectionStarted() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
    }

    static func terminalPiPDocked() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func attention() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// Fixed colors for the island chrome. The hardware Dynamic Island is an
/// opaque near-black cutout that never changes with light/dark mode or the
/// page underneath it — our drawn chrome has to match that so the collapsed
/// pills and expanded surface read as part of the same object as the real
/// island. Deliberately NOT sourced from `BrowserTheme` (whose `label`/
/// `background` intentionally flip with the system color scheme): if these
/// followed the system appearance, light mode would put light icons on a
/// still-black surface and they'd vanish — the exact white-on-white class of
/// bug this project has already shipped once.
enum IslandColors {
    /// Opaque near-black, matching the hardware island's own color in both
    /// appearances and over any page background.
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.058)
    /// Slightly raised black for the expanded shell. Keeping this one tonal
    /// step above the hardware cutout makes its real top inset perceptible
    /// without moving the inline controls away from the physical island.
    static let expandedSurface = Color(red: 0.075, green: 0.075, blue: 0.082)
    /// Light label/icon color guaranteed to contrast `surface`, regardless
    /// of system color scheme.
    static let onSurface = Color(white: 0.97)
    static let onSurfaceMuted = Color(white: 0.97).opacity(0.55)
    /// Subtle fill for an unselected control drawn on `surface` — enough to
    /// read as a tappable chip without competing with `surface` itself.
    static let controlFill = Color.white.opacity(0.14)
}

/// A small icon control for the island chrome: light-on-black in both
/// system appearances, independent of page content or system color scheme
/// (see `IslandColors`).
struct IslandIconButton: View {
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
                .foregroundStyle(selected ? IslandColors.surface : IslandColors.onSurface)
                .background {
                    Circle().fill(selected ? IslandColors.onSurface : IslandColors.controlFill)
                }
                .contentShape(Circle())
        }
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}
