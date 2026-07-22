import SwiftUI

/// Compact-width (iPhone) chrome that approximates living "in" the Dynamic
/// Island. Apps can't draw inside the island itself or receive taps on it —
/// its frame isn't exposed by any public API — so this instead draws a slim
/// glass rail across the top safe-area inset, with controls in the gutters
/// that flank where the island sits, and expands to a fuller glass surface
/// on tap. iPad keeps the regular `CompactCommandBar`.
struct IslandChrome: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore
    let aiStore: BrowserAIStore

    @State private var showTabList = false

    /// The device's own top safe-area inset (the sensor-housing band on
    /// notch/Dynamic Island devices), read directly from the key window.
    /// Deliberately not sourced from a `GeometryReader` here: a reader that
    /// also `.ignoresSafeArea`s itself reports a zeroed-out inset to its own
    /// content (the ignored edge stops being "outside" its bounds), and in
    /// testing that combination left this view's hit-testing frame out of
    /// sync with what it painted — taps landed on the canvas underneath
    /// instead of the rail. Reading the inset out-of-band sidesteps that
    /// entirely.
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        let inset = topInset
        // A conservative floor: on any Dynamic Island or notch device this
        // is comfortably past the system's own inset, so the rail still
        // clears the sensor housing even if a future device reports
        // something between the two.
        let hasSensorHousing = inset > 30
        let railHeight = max(inset, 44)

        return VStack(spacing: 0) {
            if store.islandExpanded {
                expandedSurface(topInset: inset)
            } else {
                rail(topInset: inset, railHeight: railHeight, hasSensorHousing: hasSensorHousing)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        // A tap anywhere on the canvas while expanded collapses it too;
        // BrowserView adds that behavior around the ZStack since it also
        // needs to dismiss the sidebar/AI panel the same way.
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.26), value: store.islandExpanded)
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.22), value: showTabList)
    }

    // MARK: Collapsed rail

    private func rail(topInset: CGFloat, railHeight: CGFloat, hasSensorHousing: Bool) -> some View {
        let session = store.session(for: store.activePane)
        let appearance = PageChromeAppearance.resolve(session.pageBackgroundColor)
        let scrim = GlassLegibility.scrim(for: session.pageBackgroundColor)
        // Empirically tuned against the iPhone 17 Pro simulator (402x874pt,
        // ~59pt top inset): wide enough that neither gutter button's touch
        // target reaches under the island, narrow enough that the reserve
        // doesn't eat into a landscape rail where there's no island at all.
        let centerReserve: CGFloat = hasSensorHousing ? 132 : 0
        let gutterWidth: CGFloat = 58

        return HStack(spacing: 0) {
            GlassIconButton(
                systemName: "chevron.backward",
                accessibilityLabel: "Back",
                disabled: !session.canGoBack
            ) {
                session.goBack()
            }
            .frame(width: gutterWidth, alignment: .leading)

            Spacer(minLength: centerReserve)

            GlassIconButton(
                systemName: session.isLoading ? "xmark" : "arrow.clockwise",
                accessibilityLabel: session.isLoading ? "Stop loading" : "Reload page"
            ) {
                if session.isLoading { session.stopLoading() } else { session.reload() }
            }
            .frame(width: gutterWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        // The system status bar glyphs sit roughly centered in the inset
        // band; hugging the bottom of the band keeps the rail's own
        // controls clear of them without hiding the status bar outright.
        .padding(.bottom, 4)
        .frame(height: railHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .glassSurface(
            .rect(bottomLeadingRadius: GlassMetrics.railCornerRadius, bottomTrailingRadius: GlassMetrics.railCornerRadius),
            appearance: appearance,
            scrim: scrim
        )
        .environment(\.colorScheme, appearance.colorScheme ?? systemColorScheme)
        .contentShape(Rectangle())
        .onTapGesture {
            store.islandExpanded = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.island.rail")
        .accessibilityHint("Double tap to expand the browser controls.")
    }

    // MARK: Expanded surface

    private func expandedSurface(topInset: CGFloat) -> some View {
        let session = store.session(for: store.activePane)
        let appearance = PageChromeAppearance.resolve(session.pageBackgroundColor)
        let scrim = GlassLegibility.scrim(for: session.pageBackgroundColor)
        let currentTabID = store.selectedTabID(for: store.activePane)

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                GlassIconButton(systemName: "chevron.backward", accessibilityLabel: "Back", disabled: !session.canGoBack) {
                    session.goBack()
                }
                GlassIconButton(systemName: "chevron.forward", accessibilityLabel: "Forward", disabled: !session.canGoForward) {
                    session.goForward()
                }

                AddressDisplayField(store: store, terminalStore: terminalStore, dragTabID: currentTabID)

                GlassIconButton(
                    systemName: session.isLoading ? "xmark" : "arrow.clockwise",
                    accessibilityLabel: session.isLoading ? "Stop loading" : "Reload page"
                ) {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                }
            }

            HStack(spacing: 8) {
                GlassIconButton(systemName: "terminal", accessibilityLabel: "SSH terminal", selected: terminalStore.presentedSurface != nil) {
                    terminalStore.toggleSurface()
                }
                GlassIconButton(
                    systemName: store.activeWorkspace.splitEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                    accessibilityLabel: "Split view",
                    selected: store.activeWorkspace.splitEnabled
                ) {
                    store.toggleSplit()
                }
                GlassIconButton(systemName: "plus", accessibilityLabel: "New tab") {
                    store.addTab()
                }
                GlassIconButton(systemName: "square.on.square", accessibilityLabel: "Tab list", selected: showTabList) {
                    showTabList.toggle()
                }

                Spacer(minLength: 0)

                GlassIconButton(
                    systemName: aiStore.isPresented ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
                    accessibilityLabel: aiStore.isPresented ? "Hide AI assistant" : "Open AI assistant",
                    selected: aiStore.isPresented
                ) {
                    if aiStore.isPresented { aiStore.dismiss() } else { aiStore.present() }
                }
                GlassIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Sidebar") {
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
        .padding(.top, topInset > 30 ? topInset - 10 : 12)
        .padding(.bottom, 12)
        .glassSurface(
            RoundedRectangle(cornerRadius: GlassMetrics.surfaceCornerRadius, style: .continuous),
            appearance: appearance,
            scrim: scrim
        )
        .environment(\.colorScheme, appearance.colorScheme ?? systemColorScheme)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Buttons inside the surface capture their own taps first, so
            // this only fires for taps on the surface's own background —
            // the same "tap to collapse" affordance as tapping the rail.
            // (A dedicated swipe-up-to-collapse gesture was left out: a
            // plain DragGesture on this container would compete with the
            // address field's own long-press-drag handle for the same
            // touches. Tap-to-collapse — on the rail, the surface
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
                .foregroundStyle(theme.label)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
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
    @Environment(BrowserTheme.self) private var theme

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
        // Neutral label/background pairing, not `primaryActionFill` (brand
        // green) — see the note on `GlassIconButton`.
        .foregroundStyle(isActive ? theme.background : theme.label)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: 150)
        .background {
            Capsule().fill(isActive ? AnyShapeStyle(theme.label) : AnyShapeStyle(.ultraThinMaterial))
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
    @Environment(BrowserTheme.self) private var theme
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
                .foregroundStyle(session.hasOnlySecureContent ? theme.mutedLabel : Color.orange)

            TextField(
                "Address, search, or ssh://",
                text: Binding(
                    get: { focused ? session.address : AddressDisplay.readingText(for: session.currentURL) },
                    set: { session.address = $0 }
                )
            )
            .font(.system(size: 14))
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
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: GlassMetrics.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassMetrics.controlCornerRadius, style: .continuous)
                .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 1.5)
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
