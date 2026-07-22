import SwiftUI

struct BrowserView: View {
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

    var body: some View {
        @Bindable var store = store
        @Bindable var aiStore = aiStore

        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                CompactCommandBar(store: store, terminalStore: terminalStore, aiStore: aiStore)
                WorkspaceCanvas(store: store)
                    .overlay {
                        BrowserPetOverlay(
                            browserStore: store,
                            petStore: petStore,
                            aiStore: aiStore,
                            terminalStore: terminalStore
                        )
                    }
            }
            .background(theme.background)

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

            if terminalStore.launcherEnabled {
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
            TerminalPanel(store: terminalStore)
                .environment(theme)
                .presentationDetents(phoneTerminalDetents)
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
        .task {
            // tmux @modot_* events (optional, hook-provided) surface as pet
            // speech bubbles tied to the terminal tab they came from.
            terminalStore.agentEventHandler = { notification in
                petStore.showMessage(
                    notification.petMessageText,
                    sourceTerminalTabID: notification.tabID
                )
            }
            handlePendingIntent()
            await store.prepareWebFeatures()
            await aiStore.prepareWebFeatures()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled, scenePhase == .active { store.refreshServiceStatuses() }
            }
        }
        .onChange(of: intentRouter.request) { handlePendingIntent() }
        .onChange(of: scenePhase) {
            terminalStore.handleScenePhase(scenePhase)
            if scenePhase == .background {
                store.hibernateInactiveTabs()
                store.autoArchiveStaleTabs()
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
            get: { isPad ? nil : terminalStore.presentedSurface },
            set: { terminalStore.presentedSurface = $0 }
        )
    }

    private var browserSheetDetents: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.large] : [.medium, .large]
    }

    private var phoneTerminalDetents: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.large] : [.fraction(0.62), .large]
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
