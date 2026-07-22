import SwiftUI

/// Compact-width (iPhone) chrome that reads as an extension of the Dynamic
/// Island itself: two small opaque-black pills float in the gutters on
/// either side of the real island when collapsed, and tapping either one
/// morphs the whole cluster into a black island surface with the full set
/// of controls. Apps can't draw inside the island itself or receive taps on
/// it — its frame isn't exposed by any public API — so this only ever draws
/// in the gutters around it. Devices without a Dynamic Island (and iPad)
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
        let hasSensorHousing = inset > 30

        if hasSensorHousing {
            islandCluster(topInset: inset)
                // The status bar owns taps in its band (the system's
                // scroll-to-top zone) — while it is visible, touches on the
                // pills are consumed before the app ever sees them (taps on
                // the pills did nothing while a control outside the band
                // responded normally). Hiding it releases the band, and the
                // pills were overlapping the clock anyway.
                .statusBarHidden(true)
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
                collapsedPills(clusterHeight: clusterHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Laid out in its normal, safe-area-respecting position (just below
        // the sensor housing) and then pulled up by exactly that inset via
        // `offset`, rather than `.ignoresSafeArea`. `.ignoresSafeArea`
        // painted this content in the right place, but its hit-test frame
        // didn't track the same out-of-band `topInset` this view sizes
        // itself with, so the two silently drifted apart — every tap on
        // the rail (buttons included) landed nowhere, which is why nothing
        // here had ever been verified interactively. `offset` moves
        // rendering and hit-testing by the identical single value, so they
        // can't disagree.
        .offset(y: -topInset)
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.26), value: store.islandExpanded)
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.22), value: showTabList)
    }

    // MARK: Collapsed pills

    private func collapsedPills(clusterHeight: CGFloat) -> some View {
        let session = store.session(for: store.activePane)
        // Empirically tuned against the iPhone 17 Pro simulator (402x874pt,
        // ~59pt top inset): wide enough that the reserve clears the real
        // island's own footprint, narrow enough that the two pills still
        // read as attached to it rather than floating off on their own.
        let islandReserve: CGFloat = 128
        let pillGap: CGFloat = 5
        let pillHeight = min(max(clusterHeight - 12, 30), 38)

        return HStack(spacing: pillGap) {
            pill(
                systemName: "chevron.backward",
                accessibilityLabel: "Back",
                dimmed: !session.canGoBack,
                height: pillHeight
            )
            .accessibilityIdentifier("browser.island.pill.back")

            Color.clear.frame(width: islandReserve, height: 1)

            pill(
                systemName: session.isLoading ? "xmark" : "arrow.clockwise",
                accessibilityLabel: session.isLoading ? "Stop loading" : "Reload page",
                dimmed: false,
                height: pillHeight
            )
            .accessibilityIdentifier("browser.island.pill.reload")
        }
        .frame(height: clusterHeight)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// A single collapsed-state pill. Deliberately not independently
    /// actionable (it doesn't go back or reload on its own) — every tap on
    /// the cluster expands the full island surface, where those controls
    /// live as real buttons; the pill just previews which side does what.
    /// Its own drawn size stays pill-sized, but `.padding` before
    /// `.contentShape` grows the tappable area well past that so it clears
    /// the 44pt minimum without widening the visible chip and crowding the
    /// real island.
    private func pill(
        systemName: String,
        accessibilityLabel: String,
        dimmed: Bool,
        height: CGFloat
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IslandColors.onSurface.opacity(dimmed ? 0.35 : 1))
            .frame(width: height * 1.2, height: height)
            .background(IslandColors.surface, in: Capsule())
            .padding(.vertical, 8)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                store.islandExpanded = true
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to expand the browser controls.")
    }

    // MARK: Expanded surface

    private func expandedSurface(clusterHeight: CGFloat) -> some View {
        let session = store.session(for: store.activePane)
        let currentTabID = store.selectedTabID(for: store.activePane)

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                IslandIconButton(systemName: "chevron.backward", accessibilityLabel: "Back", disabled: !session.canGoBack) {
                    session.goBack()
                }
                IslandIconButton(systemName: "chevron.forward", accessibilityLabel: "Forward", disabled: !session.canGoForward) {
                    session.goForward()
                }

                AddressDisplayField(store: store, terminalStore: terminalStore, dragTabID: currentTabID)

                IslandIconButton(
                    systemName: session.isLoading ? "xmark" : "arrow.clockwise",
                    accessibilityLabel: session.isLoading ? "Stop loading" : "Reload page"
                ) {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                }
            }

            HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.top, clusterHeight > 30 ? clusterHeight - 10 : 12)
        .padding(.bottom, 12)
        .background(IslandColors.surface, in: RoundedRectangle(cornerRadius: GlassMetrics.surfaceCornerRadius, style: .continuous))
        .padding(.horizontal, 8)
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
        .frame(height: 38)
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
