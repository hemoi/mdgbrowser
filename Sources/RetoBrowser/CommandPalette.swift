import SwiftUI
import UIKit

struct BrowserCommandPalette: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var query = ""

    let store: WorkspaceBrowserStore
    let terminalStore: TerminalWorkspaceStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .foregroundStyle(theme.mutedLabel)
                    TextField("Search commands, tabs, services…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.go)
                        .onSubmit { filteredActions.first?.perform() }
                    Text("⌘K")
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.mutedLabel)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredActions.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .padding(.vertical, 32)
                        }
                        ForEach(filteredActions) { action in
                            Button {
                                action.perform()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: action.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(theme.mutedLabel)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(action.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(theme.label)
                                        if let subtitle = action.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 10))
                                                .foregroundStyle(theme.mutedLabel)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 430)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
            .frame(maxWidth: 560)
            .padding(20)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        }
        .onAppear { searchFocused = true }
    }

    private var filteredActions: [PaletteAction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return actions }
        return actions.filter {
            $0.title.lowercased().contains(needle) || ($0.subtitle?.lowercased().contains(needle) ?? false)
        }
    }

    private var actions: [PaletteAction] {
        var result: [PaletteAction] = [
            action("New tab", "plus", "Browser") { store.addTab() },
            action("Reopen last closed tab", "clock.arrow.circlepath", "Browser", disabled: store.recentlyClosedTabs.isEmpty) {
                store.reopenLastClosedTab()
            },
            action("Archive current tab", "archivebox", "Browser") {
                store.archiveTab(store.selectedTabID(for: store.activePane))
            },
            action("Toggle split view", "rectangle.split.2x1", "Layout") { store.toggleSplit() },
            action("Open sidebar", "sidebar.left", "Layout") { store.sidebarVisible = true },
            action("Page tools", "wrench.and.screwdriver", store.currentPageTitle) { store.presentedSheet = .pageTools },
            action("Developer tools", "chevron.left.forwardslash.chevron.right", store.currentPageTitle) {
                store.presentedSheet = .developerTools
            },
            action("Site settings", "switch.2", store.currentPageURL?.host()) { store.presentedSheet = .siteSettings },
            action("Tab history and archive", "archivebox", "Browser") { store.presentedSheet = .tabArchive },
            action("Downloads", "arrow.down.circle", "Browser") { store.presentedSheet = .downloads },
            action("Website data", "externaldrive.badge.icloud", "Privacy") { store.presentedSheet = .websiteData },
            action("New tab stack", "square.stack.3d.up", "Tabs") { store.presentedSheet = .createTabStack },
            action("Refresh service status", "wave.3.right", "Services") { store.refreshServiceStatuses() },
            action("Open SSH terminal", "terminal", "SSH") {
                terminalStore.presentTerminal()
            },
            action("Manage SSH connections", "server.rack", "SSH") {
                terminalStore.presentProfiles()
            },
            action(terminalStore.launcherEnabled ? "Hide floating terminal button" : "Show floating terminal button", "circle.dashed", "SSH") {
                terminalStore.toggleLauncher()
            }
        ]

        result += store.workspaces.map { workspace in
            action(
                "Switch to \(workspace.name)",
                workspace.isPrivate ? "hand.raised.fill" : "square.grid.2x2",
                workspace.isPrivate ? "Workspace · private in-memory session" : "Workspace · isolated session"
            ) {
                store.selectWorkspace(workspace.id)
            }
        }
        result += store.activeWorkspace.tabs.map { tab in
            action(tab.title, "rectangle", URL(string: tab.urlString)?.host() ?? "Tab") {
                store.selectTab(tab.id)
            }
        }
        result += store.visibleBookmarks.map { bookmark in
            action(bookmark.title, "bookmark", bookmark.url?.host() ?? "Service") {
                store.openBookmark(bookmark.id)
            }
        }
        result += terminalStore.profiles.map { profile in
            action(profile.displayName, "server.rack", "SSH · \(profile.endpoint)") {
                terminalStore.openTab(profileID: profile.id)
            }
        }
        return result
    }

    private func action(
        _ title: String,
        _ icon: String,
        _ subtitle: String?,
        disabled: Bool = false,
        perform: @escaping @MainActor () -> Void
    ) -> PaletteAction {
        PaletteAction(title: title, icon: icon, subtitle: subtitle) {
            guard !disabled else { return }
            perform()
            dismiss()
        }
    }

    private func dismiss() {
        searchFocused = false
        store.commandPalettePresented = false
    }
}

@MainActor
private struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let subtitle: String?
    let perform: () -> Void
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
