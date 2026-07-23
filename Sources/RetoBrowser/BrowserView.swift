import SwiftUI

struct BrowserView: View {
    /// Service badges are advisory, not a live monitoring dashboard. Keeping
    /// the radio awake every minute was disproportionate on a phone; manual
    /// refresh remains available from the sidebar and command palette.
    private static let serviceRefreshInterval: Duration = .seconds(300)

    @Environment(BrowserTheme.self) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = WorkspaceBrowserStore()
    @State private var terminalStore = TerminalWorkspaceStore()
    @State private var petStore = BrowserPetStore()
    @State private var aiStore = BrowserAIStore()
    @State private var intentRouter = BrowserIntentRouter.shared
    @State private var phoneTerminalDetent: PresentationDetent = .fraction(0.62)

    var body: some View {
        @Bindable var store = store
        @Bindable var aiStore = aiStore

        ZStack(alignment: .leading) {
            if isPad {
                VStack(spacing: 0) {
                    CompactCommandBar(store: store, terminalStore: terminalStore, aiStore: aiStore)
                    WorkspaceCanvas(store: store)
                        .overlay {
                            if BrowserFeatureFlags.petEnabled {
                                BrowserPetOverlay(
                                    browserStore: store,
                                    petStore: petStore,
                                    aiStore: aiStore,
                                    terminalStore: terminalStore
                                )
                            }
                        }
                }
                .background(theme.background)
            } else {
                // The island chrome overlays the canvas rather than pushing
                // it down, so the page reaches the very top of the screen
                // when collapsed. WorkspaceCanvas itself is untouched here —
                // only its container's safe area handling changes.
                //
                // The GeometryReader is the island detector: this level of
                // the hierarchy does not ignore the safe area, so its proxy
                // reports the real sensor-housing inset — and, unlike a
                // one-shot UIKit window read, it re-evaluates when the inset
                // arrives after launch or changes on rotation. A window read
                // here raced cold launch (inset 0 → fallback bar, stuck for
                // the whole session because nothing observable changed).
                GeometryReader { proxy in
                ZStack(alignment: .top) {
                    WorkspaceCanvas(store: store)
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay {
                            if BrowserFeatureFlags.petEnabled {
                                BrowserPetOverlay(
                                    browserStore: store,
                                    petStore: petStore,
                                    aiStore: aiStore,
                                    terminalStore: terminalStore
                                )
                            }
                        }

                    IslandChrome(
                        store: store,
                        terminalStore: terminalStore,
                        aiStore: aiStore,
                        topInset: proxy.safeAreaInsets.top
                    )
                }
                .background(theme.background)
                }
            }

            if store.tabDragState != nil {
                TabDragOverlay(store: store)
                    .transition(.opacity)
                    .zIndex(6)
            }

            if store.sidebarVisible {
                theme.label.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture { closeSidebar() }
                    .transition(.opacity)

                BrowserSidebar(store: store, terminalStore: terminalStore, aiStore: aiStore)
                    .frame(width: horizontalSizeClass == .compact ? 326 : 372)
                    .transition(.move(edge: .leading))
            }

            if aiStore.isPresented {
                if horizontalSizeClass == .compact {
                    theme.label.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { aiStore.dismiss() }
                        .transition(.opacity)
                        .zIndex(4)
                }

                BrowserAIPanelHost(browserStore: store, aiStore: aiStore)
                    .zIndex(5)
            }

            if isPad, terminalStore.presentedSurface != nil {
                FloatingTerminalWindow(store: terminalStore)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(3)
            }

            if terminalStore.launcherEnabled, !terminalStore.phoneSheetMinimized {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        TerminalLauncherButton(store: terminalStore)
                            .padding(.trailing, 18)
                            .padding(.bottom, 18)
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
                .zIndex(4)
            }

            if !isPad, terminalStore.phoneSheetMinimized {
                MinimizedTerminalPiP(store: terminalStore)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(7)
            }

            if store.commandPalettePresented {
                BrowserCommandPalette(store: store, terminalStore: terminalStore)
                    .zIndex(8)
            }

            if let toast = store.toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 12, y: 5)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(9)
            }

            Button("") { store.commandPalettePresented.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityHidden(true)
        }
        .coordinateSpace(name: BrowserRootCoordinateSpace.name)
        .animation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.24), value: store.sidebarVisible)
        .animation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.26), value: store.tabDragState?.tabID)
        .animation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.24), value: aiStore.isPresented)
        .animation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.28), value: terminalStore.launcherEnabled)
        .animation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.28), value: terminalStore.presentedSurface)
        .sheet(item: $store.presentedSheet) { destination in
            BrowserManagementSheet(destination: destination, store: store)
                .environment(theme)
                .presentationDetents(browserSheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: phoneTerminalSurface) { _ in
            TerminalPanel(store: terminalStore) {
                terminalStore.minimizeSurface()
            }
                .environment(theme)
                .presentationDetents(phoneTerminalDetents, selection: phoneTerminalDetentSelection)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
                .presentationBackground(theme.background)
                .interactiveDismissDisabled(false)
        }
        .sheet(item: $store.sharePayload) { payload in
            ActivityShareSheet(url: payload.url)
        }
        .sheet(isPresented: $aiStore.settingsPresented) {
            BrowserAISettingsSheet(aiStore: aiStore)
                .environment(theme)
                .presentationDetents(browserSheetDetents)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: horizontalSizeClass, initial: true) {
            store.layoutIsCompact = horizontalSizeClass == .compact
        }
        .task {
            // tmux @modot_* events (optional, hook-provided) surface as pet
            // speech bubbles tied to the terminal tab they came from.
            if BrowserFeatureFlags.petEnabled {
                terminalStore.agentEventHandler = { notification in
                    petStore.showMessage(
                        notification.petMessageText,
                        sourceTerminalTabID: notification.tabID
                    )
                }
                terminalStore.terminalEventHandler = { event in
                    petStore.showMessage(
                        event.message,
                        sourceTerminalTabID: event.sourceTerminalTabID
                    )
                }
            }
            terminalStore.openForwardedURLHandler = { url in
                store.open(url)
                terminalStore.closeSurface()
            }
            terminalStore.resumePortForwards()
            handlePendingIntent()
            await store.prepareWebFeatures()
        }
        .task(id: scenePhase) {
            // Binding this loop to scenePhase guarantees SwiftUI cancels it
            // as soon as the app leaves the foreground; it cannot wake the
            // radio later through a stale captured phase value.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.serviceRefreshInterval)
                if !Task.isCancelled { store.refreshServiceStatuses() }
            }
        }
        .onChange(of: intentRouter.request) { handlePendingIntent() }
        .onChange(of: scenePhase, initial: true) {
            terminalStore.handleScenePhase(scenePhase)
            if scenePhase == .background {
                store.stopBackgroundActivity()
                store.hibernateInactiveTabs()
                store.autoArchiveStaleTabs()
            } else if scenePhase == .active {
                store.refreshServiceStatuses()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.hibernateInactiveTabs()
        }
        .onChange(of: store.toastMessage) {
            guard store.toastMessage != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                store.toastMessage = nil
            }
        }
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var phoneTerminalSurface: Binding<TerminalSurface?> {
        Binding(
            get: {
                guard !isPad, !terminalStore.phoneSheetMinimized else { return nil }
                return terminalStore.presentedSurface
            },
            set: { surface in
                if let surface {
                    terminalStore.presentedSurface = surface
                } else if !terminalStore.phoneSheetMinimized {
                    terminalStore.closeSurface()
                }
            }
        )
    }

    private var browserSheetDetents: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.large] : [.medium, .large]
    }

    private var phoneTerminalDetents: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.large] : [.fraction(0.62), .large]
    }

    private var phoneTerminalDetentSelection: Binding<PresentationDetent> {
        Binding(
            get: {
                if verticalSizeClass == .compact { return .large }
                return phoneTerminalDetent
            },
            set: { detent in
                phoneTerminalDetent = detent
            }
        )
    }

    private func closeSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            store.sidebarVisible = false
        }
    }

    private func handlePendingIntent() {
        guard let url = intentRouter.consumeRequest() else { return }
        store.open(url)
    }
}

#Preview("iPad") {
    BrowserView()
        .environment(BrowserTheme())
}
