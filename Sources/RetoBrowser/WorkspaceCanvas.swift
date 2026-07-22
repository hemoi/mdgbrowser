import SwiftUI
import WebKit

struct WorkspaceCanvas: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: WorkspaceBrowserStore

    static let dividerSpan: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            Group {
                switch store.splitLayout {
                case .single:
                    BrowserPaneView(store: store, pane: .primary)
                case .pair(let axis):
                    pairLayout(axis: axis, size: geometry.size)
                case .triple:
                    tripleLayout(size: geometry.size)
                case .quad:
                    quadLayout(size: geometry.size)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: store.activePane)
        }
        .background(theme.background)
        // WKWebView manages its own keyboard insets. Letting SwiftUI also
        // resize the canvas made the two fight and the whole screen shake
        // whenever the keyboard appeared (typing in a page, or the SSH
        // terminal grabbing focus).
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Whole-point sizes keep WKWebView off fractional pixel boundaries,
    /// which otherwise force continuous re-rasterizing that reads as
    /// on-screen shaking.
    private func spans(total: CGFloat, ratio: Double) -> (CGFloat, CGFloat) {
        let usable = max(total - Self.dividerSpan, 1)
        let leading = (usable * ratio).rounded()
        return (leading, usable - leading)
    }

    private func pairLayout(axis: BrowserSplitAxis, size: CGSize) -> some View {
        let total = axis == .horizontal ? size.width : size.height
        let (first, second) = spans(total: total, ratio: store.activeWorkspace.splitRatio)

        return AxisStack(axis: axis) {
            BrowserPaneView(store: store, pane: .primary)
                .paneSpan(first, along: axis)

            AdjustableSplitHandle(store: store, axis: axis, totalSpan: first + second, dimension: .column)

            BrowserPaneView(store: store, pane: .secondary)
                .paneSpan(second, along: axis)
        }
    }

    // Two panes on top, the third spanning the bottom row.
    private func tripleLayout(size: CGSize) -> some View {
        let (topHeight, bottomHeight) = spans(total: size.height, ratio: store.activeWorkspace.splitRowRatio)
        let (leftWidth, rightWidth) = spans(total: size.width, ratio: store.activeWorkspace.splitRatio)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                BrowserPaneView(store: store, pane: .primary).frame(width: leftWidth)
                AdjustableSplitHandle(store: store, axis: .horizontal, totalSpan: leftWidth + rightWidth, dimension: .column)
                BrowserPaneView(store: store, pane: .secondary).frame(width: rightWidth)
            }
            .frame(height: topHeight)

            AdjustableSplitHandle(store: store, axis: .vertical, totalSpan: topHeight + bottomHeight, dimension: .row)

            BrowserPaneView(store: store, pane: .tertiary)
                .frame(height: bottomHeight)
        }
    }

    private func quadLayout(size: CGSize) -> some View {
        let (topHeight, bottomHeight) = spans(total: size.height, ratio: store.activeWorkspace.splitRowRatio)
        let (leftWidth, rightWidth) = spans(total: size.width, ratio: store.activeWorkspace.splitRatio)

        return VStack(spacing: 0) {
            quadRow(leading: .primary, trailing: .secondary, leftWidth: leftWidth, rightWidth: rightWidth)
                .frame(height: topHeight)

            AdjustableSplitHandle(store: store, axis: .vertical, totalSpan: topHeight + bottomHeight, dimension: .row)

            quadRow(leading: .tertiary, trailing: .quaternary, leftWidth: leftWidth, rightWidth: rightWidth)
                .frame(height: bottomHeight)
        }
    }

    private func quadRow(
        leading: BrowserPane,
        trailing: BrowserPane,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            BrowserPaneView(store: store, pane: leading).frame(width: leftWidth)
            AdjustableSplitHandle(store: store, axis: .horizontal, totalSpan: leftWidth + rightWidth, dimension: .column)
            BrowserPaneView(store: store, pane: trailing).frame(width: rightWidth)
        }
    }
}

private struct AxisStack<Content: View>: View {
    let axis: BrowserSplitAxis
    @ViewBuilder let content: Content

    var body: some View {
        if axis == .horizontal {
            HStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

private extension View {
    func paneSpan(_ span: CGFloat, along axis: BrowserSplitAxis) -> some View {
        frame(
            width: axis == .horizontal ? span : nil,
            height: axis == .horizontal ? nil : span
        )
    }
}

private struct BrowserPaneView: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore
    let pane: BrowserPane

    var body: some View {
        let revision = store.webViewRevision
        let tab = store.selectedTab(for: pane)
        let browserSession = store.session(for: tab)
        @Bindable var session = browserSession

        ZStack(alignment: .top) {
            BrowserWebView(session: session) {
                store.setActivePane(pane)
            }
            .id(session.instanceID)
            .accessibilityIdentifier("browser.pane.\(pane.rawValue)")

            if session.isLoading {
                ProgressView(value: session.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(theme.tailnet)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading page")
            }

            if store.splitLayout != .single && store.activePane == pane {
                Rectangle()
                    .fill(theme.tailnet)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            // With a single pane there is nothing to rearrange, and the
            // handle would just sit on top of the page.
            if store.splitLayout != .single {
                PaneMoveHandle(store: store, tabID: tab.id)
                    .padding(.leading, 8)
                    .padding(.top, 10)
            }
        }
        .background(theme.background)
        .overlay {
            if store.splitLayout != .single {
                Rectangle()
                    .stroke(store.activePane == pane ? theme.label.opacity(0.24) : theme.border.opacity(0.7), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .task(id: revision) { session.loadIfNeeded(fallbackURLString: tab.urlString) }
        .onChange(of: session.currentURL) { store.syncTabFromSession(tab.id) }
        .onChange(of: session.title) { store.syncTabFromSession(tab.id) }
        .alert(
            "Couldn’t Open Page",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let session: BrowserSession
    var onInteraction: (() -> Void)?

    private static let focusRecognizerName = "reto.pane.focus"

    func makeUIView(context: Context) -> WKWebView {
        let webView = session.webView
        // The web view outlives this representable (tabs hop between panes),
        // so drop any focus recognizer left behind by a previous host.
        webView.gestureRecognizers?
            .filter { $0.name == Self.focusRecognizerName }
            .forEach(webView.removeGestureRecognizer)
        if let onInteraction {
            context.coordinator.onInteraction = onInteraction
            let recognizer = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleTap)
            )
            recognizer.name = Self.focusRecognizerName
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = context.coordinator
            webView.addGestureRecognizer(recognizer)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onInteraction = onInteraction
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Touching anywhere inside a pane focuses it, without stealing the touch
    // from the page.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onInteraction: (() -> Void)?

        @objc func handleTap() {
            onInteraction?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// Small grab handle at the top-left of each pane: long-press and drag to
// re-place the pane's tab through the same overview/4-way split overlay as
// dragging a tab chip.
private struct PaneMoveHandle: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore
    let tabID: UUID

    var body: some View {
        let lifted = store.tabDragState?.tabID == tabID

        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(lifted ? theme.background : theme.mutedLabel)
            .frame(width: 26, height: 26)
            .background(lifted ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.thinMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .tabDragGesture(store: store, tabID: tabID, minimumPressDuration: 0.2)
            .animation(.snappy(duration: 0.16), value: lifted)
            .accessibilityLabel("Move this pane")
            .accessibilityHint("Touch and hold, then drag to an edge to split, or across the top to switch tabs.")
            .accessibilityIdentifier("browser.pane.handle")
    }
}

private struct AdjustableSplitHandle: View {
    /// Which ratio the handle drives: the column split (left/right share) or
    /// the row split (top/bottom share of a grid).
    enum Dimension { case column, row }

    @Environment(BrowserTheme.self) private var theme
    @State private var dragStartRatio: Double?

    let store: WorkspaceBrowserStore
    let axis: BrowserSplitAxis
    let totalSpan: CGFloat
    let dimension: Dimension

    private var ratio: Double {
        dimension == .column ? store.activeWorkspace.splitRatio : store.activeWorkspace.splitRowRatio
    }

    private func setRatio(_ value: Double, persistImmediately: Bool) {
        if dimension == .column {
            store.setSplitRatio(value, persistImmediately: persistImmediately)
        } else {
            store.setSplitRowRatio(value, persistImmediately: persistImmediately)
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.border)
                .frame(
                    width: axis == .horizontal ? 0.5 : nil,
                    height: axis == .horizontal ? nil : 0.5
                )

            Capsule()
                .fill(theme.mutedLabel.opacity(dragStartRatio == nil ? 0.6 : 1))
                .frame(
                    width: axis == .horizontal ? 3 : (dragStartRatio == nil ? 28 : 44),
                    height: axis == .horizontal ? (dragStartRatio == nil ? 28 : 44) : 3
                )
                .animation(.snappy(duration: 0.18), value: dragStartRatio == nil)
        }
        .frame(
            width: axis == .horizontal ? 12 : nil,
            height: axis == .horizontal ? nil : 12
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartRatio == nil { dragStartRatio = ratio }
                    let start = dragStartRatio ?? ratio
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    // Persisting every tick JSON-encodes the full snapshot on
                    // the main thread mid-drag; defer it to the gesture end.
                    setRatio(start + Double(translation / totalSpan), persistImmediately: false)
                }
                .onEnded { _ in
                    dragStartRatio = nil
                    store.persistSplitRatio()
                }
        )
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { ratio },
                    set: { setRatio($0, persistImmediately: true) }
                ),
                in: 0.25...0.75,
                step: 0.05
            )
            .accessibilityLabel("Resize split view")
            .accessibilityValue("\(Int(ratio * 100)) percent \(axis == .horizontal ? "left" : "top")")
        }
    }
}
