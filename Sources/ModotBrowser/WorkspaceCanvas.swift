import SwiftUI
import WebKit

struct WorkspaceCanvas: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: WorkspaceBrowserStore

    var body: some View {
        GeometryReader { geometry in
            if store.activeWorkspace.splitEnabled {
                let axis = store.activeWorkspace.splitAxis
                let dividerSpan: CGFloat = 12
                // Whole-point sizes keep WKWebView off fractional pixel
                // boundaries, which otherwise force continuous re-rasterizing
                // that reads as on-screen shaking.
                let totalSpan = max((axis == .horizontal ? geometry.size.width : geometry.size.height) - dividerSpan, 1)
                let primarySpan = (totalSpan * store.activeWorkspace.splitRatio).rounded()

                splitLayout(
                    axis: axis,
                    primarySpan: primarySpan,
                    secondarySpan: totalSpan - primarySpan,
                    totalSpan: totalSpan
                )
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: store.activePane)
            } else {
                BrowserPaneView(store: store, pane: .primary)
            }
        }
        .background(theme.background)
        // WKWebView manages its own keyboard insets. Letting SwiftUI also
        // resize the canvas made the two fight and the whole screen shake
        // whenever the keyboard appeared (typing in a page, or the SSH
        // terminal grabbing focus).
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private func splitLayout(
        axis: BrowserSplitAxis,
        primarySpan: CGFloat,
        secondarySpan: CGFloat,
        totalSpan: CGFloat
    ) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                BrowserPaneView(store: store, pane: .primary)
                    .frame(width: primarySpan)

                AdjustableSplitHandle(store: store, axis: axis, totalSpan: totalSpan)

                BrowserPaneView(store: store, pane: .secondary)
                    .frame(width: secondarySpan)
            }
        } else {
            VStack(spacing: 0) {
                BrowserPaneView(store: store, pane: .primary)
                    .frame(height: primarySpan)

                AdjustableSplitHandle(store: store, axis: axis, totalSpan: totalSpan)

                BrowserPaneView(store: store, pane: .secondary)
                    .frame(height: secondarySpan)
            }
        }
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

            if store.activeWorkspace.splitEnabled && store.activePane == pane {
                Rectangle()
                    .fill(theme.tailnet)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            PaneMoveHandle(store: store, tabID: tab.id)
                .padding(.leading, 8)
                .padding(.top, 10)
        }
        .background(theme.background)
        .overlay {
            if store.activeWorkspace.splitEnabled {
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

    private static let focusRecognizerName = "modot.pane.focus"

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
            .background(lifted ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.background.opacity(0.9)))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.border, lineWidth: 0.75)
            }
            .contentShape(Rectangle())
            .tabDragGesture(store: store, tabID: tabID, minimumPressDuration: 0.2)
            .animation(.snappy(duration: 0.16), value: lifted)
            .accessibilityLabel("Move this pane")
            .accessibilityHint("Touch and hold, then drag to an edge to split, or across the top to switch tabs.")
            .accessibilityIdentifier("browser.pane.handle")
    }
}

private struct AdjustableSplitHandle: View {
    @Environment(BrowserTheme.self) private var theme
    @State private var dragStartRatio: Double?

    let store: WorkspaceBrowserStore
    let axis: BrowserSplitAxis
    let totalSpan: CGFloat

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
                    if dragStartRatio == nil {
                        dragStartRatio = store.activeWorkspace.splitRatio
                    }
                    let start = dragStartRatio ?? store.activeWorkspace.splitRatio
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    // Persisting every tick JSON-encodes the full snapshot on
                    // the main thread mid-drag; defer it to the gesture end.
                    store.setSplitRatio(
                        start + Double(translation / totalSpan),
                        persistImmediately: false
                    )
                }
                .onEnded { _ in
                    dragStartRatio = nil
                    store.persistSplitRatio()
                }
        )
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { store.activeWorkspace.splitRatio },
                    set: { store.setSplitRatio($0) }
                ),
                in: 0.25...0.75,
                step: 0.05
            )
            .accessibilityLabel("Resize split view")
            .accessibilityValue("\(Int(store.activeWorkspace.splitRatio * 100)) percent \(axis == .horizontal ? "left" : "top")")
        }
    }
}
