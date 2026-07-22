import SwiftUI
import UIKit

/// Pure geometry for the full-width tab overview strip. Rendering and
/// drop-target resolution share this math so the tab drawn under the finger
/// is always the tab that gets selected on release.
struct TabOverviewLayout: Equatable {
    let containerWidth: CGFloat
    let tabCount: Int

    static let stripHeight: CGFloat = 64
    static let itemHeight: CGFloat = 40
    static let horizontalInset: CGFloat = 12
    static let itemSpacing: CGFloat = 6
    static let maxItemWidth: CGFloat = 168
    static let minItemWidth: CGFloat = 26
    static let magnification: CGFloat = 0.26
    static let magnificationRadius: CGFloat = 88

    var itemWidth: CGFloat {
        guard tabCount > 0 else { return 0 }
        let available = containerWidth
            - Self.horizontalInset * 2
            - CGFloat(tabCount - 1) * Self.itemSpacing
        return min(Self.maxItemWidth, max(Self.minItemWidth, available / CGFloat(tabCount)))
    }

    var contentWidth: CGFloat {
        guard tabCount > 0 else { return 0 }
        return CGFloat(tabCount) * itemWidth + CGFloat(tabCount - 1) * Self.itemSpacing
    }

    var originX: CGFloat {
        max(Self.horizontalInset, (containerWidth - contentWidth) / 2)
    }

    func midX(at index: Int) -> CGFloat {
        originX + CGFloat(index) * (itemWidth + Self.itemSpacing) + itemWidth / 2
    }

    /// Index of the tab under the finger, clamped to the strip so a finger
    /// slightly past either edge still lands on the nearest tab.
    func index(at x: CGFloat) -> Int? {
        guard tabCount > 0, itemWidth > 0 else { return nil }
        let slot = (x - originX) / (itemWidth + Self.itemSpacing)
        return min(max(Int(slot.rounded(.down)), 0), tabCount - 1)
    }

    /// Dock-style magnification: 1.0 away from the finger rising smoothly to
    /// 1 + magnification directly beneath it.
    func scale(forItemAt index: Int, fingerX: CGFloat?) -> CGFloat {
        guard let fingerX else { return 1 }
        let distance = abs(midX(at: index) - fingerX)
        guard distance < Self.magnificationRadius else { return 1 }
        let normalized = distance / Self.magnificationRadius
        let falloff = (cos(normalized * .pi) + 1) / 2
        return 1 + Self.magnification * falloff
    }
}

/// Maps a finger location to a drag target. Below the overview strip the
/// whole canvas is a drop surface: the nearest edge decides the split
/// placement (left/right → side-by-side, top/bottom → stacked), with a
/// neutral dead zone in the center for cancelling.
struct TabDragGeometry: Equatable {
    let containerSize: CGSize
    let tabCount: Int

    static let overviewGraceHeight: CGFloat = 36
    /// Fraction of the drop canvas around its center where releasing cancels.
    static let neutralFraction: CGFloat = 0.24

    var layout: TabOverviewLayout {
        TabOverviewLayout(containerWidth: containerSize.width, tabCount: tabCount)
    }

    var overviewMaxY: CGFloat { TabOverviewLayout.stripHeight + Self.overviewGraceHeight }

    var dropCanvas: CGRect {
        CGRect(
            x: 0,
            y: overviewMaxY,
            width: containerSize.width,
            height: max(containerSize.height - overviewMaxY, 1)
        )
    }

    func isInOverview(_ location: CGPoint) -> Bool {
        location.y <= overviewMaxY
    }

    func placement(at location: CGPoint) -> SplitPlacement? {
        guard !isInOverview(location) else { return nil }
        let canvas = dropCanvas
        let nx = min(max((location.x - canvas.minX) / canvas.width, 0), 1)
        let ny = min(max((location.y - canvas.minY) / canvas.height, 0), 1)
        if abs(nx - 0.5) < Self.neutralFraction / 2, abs(ny - 0.5) < Self.neutralFraction / 2 {
            return nil
        }
        let distances: [(SplitPlacement, CGFloat)] = [
            (.leading, nx), (.trailing, 1 - nx), (.top, ny), (.bottom, 1 - ny)
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0
    }

    func target(at location: CGPoint, tabIDs: [UUID]) -> TabDragTarget? {
        if isInOverview(location) {
            guard let index = layout.index(at: location.x), tabIDs.indices.contains(index) else { return nil }
            return .tab(tabIDs[index])
        }
        return placement(at: location).map(TabDragTarget.split)
    }

    /// The half of the canvas the tab would occupy for a given placement,
    /// used to preview the resulting split.
    func previewRect(for placement: SplitPlacement) -> CGRect {
        let canvas = dropCanvas
        switch placement {
        case .leading:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        case .trailing:
            return CGRect(x: canvas.midX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
        case .top:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
        case .bottom:
            return CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
        }
    }
}

/// Full-screen, non-interactive overlay shown while a tab is being
/// long-press dragged: the overview strip across the top and, once the
/// finger leaves it, edge-based split drop targets with a live preview of
/// the half the tab would fill.
struct TabDragOverlay: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: WorkspaceBrowserStore

    var body: some View {
        GeometryReader { geometry in
            if let dragState = store.tabDragState {
                let tabs = store.visibleOrderedTabs
                let geometryModel = TabDragGeometry(containerSize: geometry.size, tabCount: tabs.count)
                let fingerLocation = dragState.location
                let inOverview = fingerLocation.map(geometryModel.isInOverview) ?? true

                ZStack(alignment: .top) {
                    theme.label.opacity(0.14)

                    if let fingerLocation, !geometryModel.isInOverview(fingerLocation) {
                        splitDropSurface(geometryModel: geometryModel, target: dragState.target)
                            .transition(.opacity)
                    }

                    overviewStrip(
                        tabs: tabs,
                        layout: geometryModel.layout,
                        dragState: dragState,
                        magnifying: inOverview
                    )

                    if let fingerLocation, let tab = tabs.first(where: { $0.id == dragState.tabID }) {
                        draggedChip(tab)
                            .position(x: fingerLocation.x, y: max(fingerLocation.y - 40, 18))
                    }
                }
                .animation(
                    reduceMotion ? .linear(duration: 0.1) : .snappy(duration: 0.22),
                    value: dragState.target
                )
                .onChange(of: dragState.location, initial: true) {
                    guard let location = store.tabDragState?.location else { return }
                    store.updateTabDragTarget(
                        geometryModel.target(at: location, tabIDs: tabs.map(\.id))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func overviewStrip(
        tabs: [BrowserTabRecord],
        layout: TabOverviewLayout,
        dragState: TabDragState,
        magnifying: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let fingerX = magnifying ? dragState.location?.x : nil
                let scale = reduceMotion ? 1 : layout.scale(forItemAt: index, fingerX: fingerX)
                let hovered = dragState.target == .tab(tab.id) && magnifying

                overviewItem(tab, width: layout.itemWidth, hovered: hovered, dragged: tab.id == dragState.tabID)
                    .scaleEffect(scale, anchor: .bottom)
                    .position(
                        x: layout.midX(at: index),
                        y: TabOverviewLayout.stripHeight - TabOverviewLayout.itemHeight / 2 - 8
                    )
                    .animation(
                        reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.82),
                        value: scale
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: TabOverviewLayout.stripHeight)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    private func overviewItem(_ tab: BrowserTabRecord, width: CGFloat, hovered: Bool, dragged: Bool) -> some View {
        VStack(spacing: 3) {
            if width >= 56 {
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(hovered ? theme.background : theme.label)
                    .padding(.horizontal, 6)
            } else {
                Circle()
                    .fill(hovered ? theme.background : theme.mutedLabel)
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: width, height: TabOverviewLayout.itemHeight)
        .background(hovered ? theme.accent : theme.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    dragged && !hovered ? theme.label.opacity(0.5) : theme.border,
                    lineWidth: dragged && !hovered ? 1 : 0.5
                )
        }
    }

    @ViewBuilder
    private func splitDropSurface(geometryModel: TabDragGeometry, target: TabDragTarget?) -> some View {
        let canvas = geometryModel.dropCanvas

        // Live preview of the half the tab would occupy.
        if case .split(let placement) = target {
            let rect = geometryModel.previewRect(for: placement)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.label.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.accent, lineWidth: 1.5)
                }
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: placement.previewSymbol)
                            .font(.system(size: 24, weight: .medium))
                        Text(placement.previewTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(theme.label)
                }
                .frame(width: rect.width - 12, height: rect.height - 12)
                .position(x: rect.midX, y: rect.midY)
        }

        // Edge hints for the four placements.
        ForEach(SplitPlacement.allTargets, id: \.self) { placement in
            let hovered = target == .split(placement)
            let hint = hintCenter(for: placement, in: canvas)
            Image(systemName: placement.previewSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovered ? theme.background : theme.label)
                .frame(width: 40, height: 40)
                .background(hovered ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.background.opacity(0.94)))
                .clipShape(Circle())
                .overlay { Circle().stroke(hovered ? theme.accent : theme.border, lineWidth: 1) }
                .scaleEffect(hovered ? 1.12 : 1)
                .position(hint)
        }
    }

    private func hintCenter(for placement: SplitPlacement, in canvas: CGRect) -> CGPoint {
        let inset: CGFloat = 34
        switch placement {
        case .leading: return CGPoint(x: canvas.minX + inset, y: canvas.midY)
        case .trailing: return CGPoint(x: canvas.maxX - inset, y: canvas.midY)
        case .top: return CGPoint(x: canvas.midX, y: canvas.minY + inset)
        case .bottom: return CGPoint(x: canvas.midX, y: canvas.maxY - inset)
        }
    }

    private func draggedChip(_ tab: BrowserTabRecord) -> some View {
        Text(tab.title)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(theme.label)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: 180)
            .background(theme.background)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(theme.border, lineWidth: 0.75) }
    }
}

extension SplitPlacement {
    static let allTargets: [SplitPlacement] = [.leading, .trailing, .top, .bottom]

    var previewSymbol: String {
        switch self {
        case .leading: "rectangle.lefthalf.filled"
        case .trailing: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        }
    }

    var previewTitle: String {
        switch self {
        case .leading: "Split left"
        case .trailing: "Split right"
        case .top: "Split top"
        case .bottom: "Split bottom"
        }
    }
}

enum TabDragHaptics {
    @MainActor static func dragBegan() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor static func targetChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Long-press then drag, reported in the browser root coordinate space so
/// TabDragOverlay's hit testing lines up. Shared by the tab strip chips and
/// the per-pane move handles.
struct TabDragGestureModifier: ViewModifier {
    @GestureState private var isDraggingTab = false

    let store: WorkspaceBrowserStore
    let tabID: UUID
    var minimumPressDuration: Double = 0.3

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: minimumPressDuration)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(BrowserRootCoordinateSpace.name)))
                    .updating($isDraggingTab) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        switch value {
                        case .second(true, nil):
                            if store.tabDragState == nil {
                                store.beginTabDrag(tabID)
                            }
                        case .second(true, .some(let drag)):
                            if store.tabDragState == nil {
                                store.beginTabDrag(tabID, at: drag.location)
                            } else {
                                store.updateTabDrag(location: drag.location)
                            }
                        default:
                            break
                        }
                    }
                    .onEnded { value in
                        switch value {
                        case .second(true, _):
                            store.finishTabDrag()
                        default:
                            store.cancelTabDrag()
                        }
                    }
            )
            .onChange(of: isDraggingTab) {
                // GestureState resets on cancellation paths that skip
                // onEnded; a completed drag has already cleared the state,
                // so this only tears down an abandoned one.
                if !isDraggingTab { store.cancelTabDrag() }
            }
    }
}

extension View {
    func tabDragGesture(
        store: WorkspaceBrowserStore,
        tabID: UUID,
        minimumPressDuration: Double = 0.3
    ) -> some View {
        modifier(
            TabDragGestureModifier(
                store: store,
                tabID: tabID,
                minimumPressDuration: minimumPressDuration
            )
        )
    }
}
