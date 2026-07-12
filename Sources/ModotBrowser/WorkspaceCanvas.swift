import SwiftUI
import WebKit

struct WorkspaceCanvas: View {
    @Environment(BrowserTheme.self) private var theme

    let store: WorkspaceBrowserStore

    var body: some View {
        GeometryReader { geometry in
            if store.activeWorkspace.splitEnabled {
                let dividerWidth: CGFloat = 12
                let availableWidth = max(geometry.size.width - dividerWidth, 1)
                let primaryWidth = availableWidth * store.activeWorkspace.splitRatio

                HStack(spacing: 0) {
                    BrowserPaneView(store: store, pane: .primary)
                        .frame(width: primaryWidth)

                    AdjustableSplitHandle(store: store, totalWidth: availableWidth)

                    BrowserPaneView(store: store, pane: .secondary)
                        .frame(width: availableWidth - primaryWidth)
                }
            } else {
                BrowserPaneView(store: store, pane: .primary)
            }
        }
        .background(theme.background)
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
            BrowserWebView(session: session)
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

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

private struct AdjustableSplitHandle: View {
    @Environment(BrowserTheme.self) private var theme
    @State private var dragStartRatio: Double?

    let store: WorkspaceBrowserStore
    let totalWidth: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.border)
                .frame(width: 0.5)

            Capsule()
                .fill(theme.mutedLabel.opacity(0.6))
                .frame(width: 3, height: 28)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartRatio == nil {
                        dragStartRatio = store.activeWorkspace.splitRatio
                    }
                    let start = dragStartRatio ?? store.activeWorkspace.splitRatio
                    store.setSplitRatio(start + Double(value.translation.width / totalWidth))
                }
                .onEnded { _ in dragStartRatio = nil }
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
            .accessibilityValue("\(Int(store.activeWorkspace.splitRatio * 100)) percent left")
        }
    }
}
