import SwiftUI
import UIKit

/// Compact-width (iPhone) chrome that reads as an extension of the Dynamic
/// Island itself: time, Back, the hardware island, Reload, and battery share
/// one compact rail. A long press morphs that rail downward into the full
/// browser surface. Apps can't draw inside the island or receive taps in the
/// system-owned status bar, so this view replaces the system indicators with
/// live in-app equivalents while the rail is active. Devices without a
/// sensor housing (and iPad)
/// fall back to the regular `CompactCommandBar`.
struct IslandChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    /// The device's top safe-area inset (the sensor-housing band on
    /// notch/Dynamic Island devices), supplied by BrowserView from a
    /// GeometryReader at a level of the hierarchy that does not ignore the
    /// safe area. Passed in rather than read from UIKit windows here: a
    /// window read raced cold launch (inset 0 before any window was laid
    /// out) and, being non-observable, never re-evaluated — the app stayed
    /// on the fallback bar for the whole session. The proxy value is
    /// reactive: it updates when the inset arrives and on rotation.
    let topInset: CGFloat

    @State private var showTabList = false
    @State private var batteryLevel: Float = -1

    var body: some View {
        let inset = topInset
        // A conservative floor: on any Dynamic Island device this is
        // comfortably past the system's own inset, so we don't mistake a
        // plain notch (or landscape, where the housing moves to the side
        // and this inset collapses toward 0) for a Dynamic Island. Devices
        // that fail this check get the regular command bar instead — "the
        // original way" — which also means landscape on an island device
        // falls back to the bar rather than trying to float pills next to
        // a housing that isn't on the top edge anymore.
        let hasSensorHousing = inset > 50

        if hasSensorHousing {
            islandCluster(topInset: inset)
                .statusBarHidden(true)
                .onAppear(perform: refreshBatteryLevel)
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                    refreshBatteryLevel()
                }
        } else {
            CompactCommandBar(store: store, terminalStore: terminalStore, aiStore: aiStore)
        }
    }

    // MARK: Cluster container

    private func islandCluster(topInset: CGFloat) -> some View {
        let clusterHeight = max(topInset, 44)

        return VStack(spacing: 0) {
            if store.islandExpanded {
                expandedSurface(clusterHeight: clusterHeight)
            } else {
                islandRail(clusterHeight: clusterHeight, embedded: false)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Hiding the system status bar releases this band for interaction.
        // The rail supplies live time and battery indicators in the same
        // positions, so the island can be one continuous, tappable line.
        .offset(y: -topInset)
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.26), value: store.islandExpanded)
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.22), value: showTabList)
    }

    // MARK: Island rail

    private func islandRail(clusterHeight: CGFloat, embedded: Bool) -> some View {
        let session = store.session(for: store.activePane)
        // Empirically tuned against the iPhone 17 Pro simulator (402x874pt,
        // ~59pt top inset): wide enough that the reserve clears the real
        // island's own footprint, narrow enough that the two pills still
        // read as attached to it rather than floating off on their own.
        let islandReserve: CGFloat = 120
        let pillHeight: CGFloat = 36
        let statusColor = embedded ? IslandColors.onSurface : Color.primary

        return HStack(spacing: 0) {
            statusTime(color: statusColor)

            Spacer(minLength: 0)

            pill(
                systemName: "chevron.backward",
                accessibilityLabel: "Back",
                dimmed: !session.canGoBack,
                height: pillHeight,
                embedded: embedded,
                action: { if session.canGoBack { session.goBack() } }
            )
            .accessibilityIdentifier("browser.island.pill.back")

            Color.clear.frame(width: islandReserve, height: 1)

            pill(
                systemName: session.isLoading ? "xmark" : "arrow.clockwise",
                accessibilityLabel: session.isLoading ? "Stop loading" : "Reload page",
                dimmed: false,
                height: pillHeight,
                embedded: embedded,
                action: {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                }
            )
            .accessibilityIdentifier("browser.island.pill.reload")

            Spacer(minLength: 0)

            statusIndicators(color: statusColor)
        }
        .padding(.horizontal, 12)
        .frame(height: clusterHeight)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statusTime(color: Color) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(statusClockText(context.date))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(width: 58, alignment: .leading)
        .accessibilityLabel("Current time")
    }

    private func statusIndicators(color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi")
                .font(.system(size: 13, weight: .semibold))

            Image(systemName: batterySymbol)
                .font(.system(size: 17, weight: .medium))
        }
        .foregroundStyle(color)
        .frame(width: 58, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Wi-Fi, battery \(batteryPercentage) percent"))
    }

    /// A collapsed control performs its visible action on tap and expands
    /// the browser surface on a deliberate long press. The visible capsule
    /// is compact, while the outer frame preserves a 44pt touch target.
    private func pill(
        systemName: String,
        accessibilityLabel: String,
        dimmed: Bool,
        height: CGFloat,
        embedded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IslandColors.onSurface.opacity(dimmed ? 0.35 : 1))
            .frame(width: height * 1.18, height: height)
            .background(embedded ? IslandColors.controlFill : IslandColors.surface, in: Capsule())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.38)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first:
                            store.islandExpanded = true
                        case .second:
                            action()
                        }
                    }
            )
            .accessibilityAction {
                action()
            }
            .accessibilityAction(named: "Expand browser controls") {
                store.islandExpanded = true
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to activate. Touch and hold to expand browser controls.")
    }

    // MARK: Expanded surface

    private func expandedSurface(clusterHeight: CGFloat) -> some View {
        let session = store.session(for: store.activePane)
        let currentTabID = store.selectedTabID(for: store.activePane)

        return VStack(spacing: 8) {
            islandRail(clusterHeight: clusterHeight, embedded: true)

            AddressDisplayField(store: store, terminalStore: terminalStore, dragTabID: currentTabID)

            HStack(spacing: 0) {
                IslandIconButton(systemName: "chevron.forward", accessibilityLabel: "Forward", disabled: !session.canGoForward) {
                    session.goForward()
                }
                IslandIconButton(systemName: "terminal", accessibilityLabel: "SSH terminal", selected: terminalStore.presentedSurface != nil) {
                    terminalStore.toggleSurface()
                }
                IslandIconButton(
                    systemName: store.activeWorkspace.splitEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                    accessibilityLabel: "Split view",
                    selected: store.activeWorkspace.splitEnabled
                ) {
                    store.toggleSplit()
                }
                IslandIconButton(systemName: "plus", accessibilityLabel: "New tab") {
                    store.addTab()
                }
                IslandIconButton(systemName: "square.on.square", accessibilityLabel: "Tab list", selected: showTabList) {
                    showTabList.toggle()
                }

                Spacer(minLength: 0)

                IslandIconButton(
                    systemName: aiStore.isPresented ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
                    accessibilityLabel: aiStore.isPresented ? "Hide AI assistant" : "Open AI assistant",
                    selected: aiStore.isPresented
                ) {
                    if aiStore.isPresented { aiStore.dismiss() } else { aiStore.present() }
                }
                IslandIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Sidebar") {
                    store.sidebarVisible = true
                    store.islandExpanded = false
                }
                islandMenu
            }

            if showTabList {
                IslandTabList(store: store)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .background(IslandColors.surface, in: RoundedRectangle(cornerRadius: GlassMetrics.surfaceCornerRadius, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            // Buttons inside the surface capture their own taps first, so
            // this only fires for taps on the surface's own background —
            // the same "tap to collapse" affordance as tapping a pill.
            // (A dedicated swipe-up-to-collapse gesture was left out: a
            // plain DragGesture on this container would compete with the
            // address field's own long-press-drag handle for the same
            // touches. Tap-to-collapse — on a pill, the surface
            // background, or the canvas below — covers dismissal instead.)
            store.islandExpanded = false
        }
        .accessibilityIdentifier("browser.island.surface")
    }

    private var batteryPercentage: Int {
        guard batteryLevel >= 0 else { return 100 }
        return Int((batteryLevel * 100).rounded())
    }

    private var batterySymbol: String {
        switch batteryPercentage {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func statusClockText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private func refreshBatteryLevel() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
    }

    private var islandMenu: some View {
        let session = store.session(for: store.activePane)
        let currentTab = store.selectedTab(for: store.activePane)
        let currentTabID = currentTab.id

        return Menu {
            Section {
                Button {
                    store.quickToggleBookmark()
                } label: {
                    if store.isBookmarked(session.currentURL) {
                        Label("Remove bookmark", systemImage: "star.fill")
                    } else {
                        Label("Bookmark this page", systemImage: "star")
                    }
                }
                .disabled(session.currentURL == nil)

                Button("Site settings", systemImage: "shield.lefthalf.filled") { store.presentedSheet = .siteSettings }
                Button("Page tools", systemImage: "wrench.and.screwdriver") { store.presentedSheet = .pageTools }
                Button("Developer tools", systemImage: "chevron.left.forwardslash.chevron.right") {
                    store.presentedSheet = .developerTools
                }
            }

            Section {
                Button("Command palette", systemImage: "command") { store.commandPalettePresented = true }
                Button("Reopen closed tab", systemImage: "clock.arrow.circlepath") { store.reopenLastClosedTab() }
                    .disabled(store.recentlyClosedTabs.isEmpty)
                Button("Tab history", systemImage: "tray.full") { store.presentedSheet = .tabArchive }
                Button("Downloads", systemImage: "arrow.down.circle") { store.presentedSheet = .downloads }
            }

            Section {
                Button(currentTab.isPinned ? "Unpin tab" : "Pin tab", systemImage: "pin") {
                    store.toggleTabPin(currentTabID)
                }
                Button("Archive tab", systemImage: "archivebox") { store.archiveTab(currentTabID) }
                Button("Close tab", systemImage: "xmark", role: .destructive) { store.closeTab(currentTabID) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IslandColors.onSurface)
                .frame(width: 34, height: 34)
                .background(IslandColors.controlFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More browser actions")
        .accessibilityIdentifier("browser.island.menu")
    }
}

/// A compact horizontal list of the active workspace's tabs, shown inside
/// the expanded island surface when "Tab list" is toggled on. Distinct from
/// `TabDragOverlay`'s full-screen overview, which only appears mid-drag.
private struct IslandTabList: View {
    let store: WorkspaceBrowserStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.visibleOrderedTabs) { tab in
                    tabChip(tab)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 44)
    }

    private func tabChip(_ tab: BrowserTabRecord) -> some View {
        let isActive = store.selectedTabID(for: store.activePane) == tab.id

        return HStack(spacing: 6) {
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(isActive ? IslandColors.surface : IslandColors.onSurface)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: 150)
        .background {
            Capsule().fill(isActive ? AnyShapeStyle(IslandColors.onSurface) : AnyShapeStyle(IslandColors.controlFill))
        }
        .contentShape(Capsule())
        .onTapGesture {
            store.selectTab(tab.id, for: store.activePane)
        }
        .accessibilityLabel(tab.title.isEmpty ? "New Tab" : tab.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// The address field for the expanded island surface: a short "reading"
/// form when unfocused (see `AddressDisplay`), the exact URL when editing,
/// and a long-press-drag handle onto the shared tab-drag machinery so a
/// horizontal drag scrubs the tab overview and a downward drag opens the
/// split targets — exactly like dragging a tab chip.
private struct AddressDisplayField: View {
    @FocusState private var focused: Bool

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let dragTabID: UUID

    var body: some View {
        let browserSession = store.session(for: store.activePane)
        @Bindable var session = browserSession

        HStack(spacing: 6) {
            Image(systemName: session.hasOnlySecureContent ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.hasOnlySecureContent ? IslandColors.onSurfaceMuted : Color.orange)

            TextField(
                "",
                text: Binding(
                    get: { focused ? session.address : AddressDisplay.readingText(for: session.currentURL) },
                    set: { session.address = $0 }
                ),
                prompt: Text("Address, search, or ssh://").foregroundStyle(IslandColors.onSurfaceMuted)
            )
            .font(.system(size: 14))
            .foregroundStyle(IslandColors.onSurface)
            .tint(IslandColors.onSurface)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .focused($focused)
            .onSubmit(submit)
            // Reading state doesn't need the field to keep stretching once
            // its shortened text is much narrower than the full URL would
            // have been; editing state still wants the room.
            .fixedSize(horizontal: false, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(IslandColors.controlFill, in: RoundedRectangle(cornerRadius: GlassMetrics.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassMetrics.controlCornerRadius, style: .continuous)
                .stroke(focused ? IslandColors.onSurface : Color.clear, lineWidth: 1.5)
        }
        .tabDragGesture(store: store, tabID: dragTabID, simultaneous: true)
        .accessibilityIdentifier("browser.address")
        .accessibilityHint("Touch and hold, then drag sideways to switch tabs, or down to split.")
    }

    private func submit() {
        let session = store.session(for: store.activePane)
        let submittedAddress = session.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if submittedAddress.lowercased().hasPrefix("ssh://") {
            if let profile = SSHProfile.draft(fromSSHAddress: submittedAddress) {
                terminalStore.presentProfileEditor(profile)
            } else {
                session.errorMessage = "Use an SSH address like ssh://user@host or ssh://user@host:port."
            }
        } else {
            store.submitAddress()
        }
        focused = false
    }
}
