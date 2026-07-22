import SwiftUI

struct BrowserManagementSheet: View {
    let destination: BrowserSheetDestination
    let store: WorkspaceBrowserStore

    var body: some View {
        switch destination {
        case .addWorkspace:
            AddWorkspaceSheet(store: store)
        case .addGroup:
            AddGroupSheet(store: store)
        case .addBookmark(let title, let url):
            AddBookmarkSheet(store: store, initialTitle: title, initialURL: url)
        case .createTabStack:
            CreateTabStackSheet(store: store)
        case .siteSettings:
            SiteSettingsSheet(store: store)
        case .pageTools:
            PageToolsSheet(store: store)
        case .developerTools:
            BrowserDeveloperToolsSheet(store: store)
        case .tabArchive:
            TabArchiveSheet(store: store)
        case .downloads:
            DownloadsSheet(store: store)
        }
    }
}

private struct AddWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    let store: WorkspaceBrowserStore

    var body: some View {
        ManagementSheetScaffold(title: "New Workspace", confirmTitle: "Create", canConfirm: !trimmedName.isEmpty) {
            Section {
                TextField("Work, Personal, Ops…", text: $name)
            }
        } onConfirm: {
            store.addWorkspace(name: trimmedName)
            dismiss()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AddGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    let store: WorkspaceBrowserStore

    var body: some View {
        ManagementSheetScaffold(title: "New Group", confirmTitle: "Create", canConfirm: !trimmedName.isEmpty) {
            Section {
                TextField("Tailnet, Dev tools…", text: $name)
            }
        } onConfirm: {
            store.addGroup(name: trimmedName)
            dismiss()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AddBookmarkSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var url: String
    @State private var groupID: UUID?
    @State private var workspaceID: UUID?
    @State private var isPinned = true

    let store: WorkspaceBrowserStore

    init(store: WorkspaceBrowserStore, initialTitle: String, initialURL: String) {
        self.store = store
        _title = State(initialValue: initialTitle)
        _url = State(initialValue: initialURL)
        _groupID = State(initialValue: store.groups.first?.id)
        _workspaceID = State(initialValue: store.activeWorkspaceID)
    }

    var body: some View {
        ManagementSheetScaffold(title: "New Bookmark", confirmTitle: "Save", canConfirm: BrowserURL.resolve(url) != nil) {
            Section {
                LabeledContent("Name") {
                    TextField("Codex", text: $title)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Address") {
                    TextField("https://service.tailnet.ts.net", text: $url)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }

            Section("Organize") {
                Picker("Workspace", selection: $workspaceID) {
                    Text("All workspaces").tag(UUID?.none)
                    ForEach(store.workspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                Picker("Group", selection: $groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
            }

            Section {
                Toggle("Keep in command bar", isOn: $isPinned)
            }
        } onConfirm: {
            store.addBookmark(
                title: title, urlString: url, groupID: groupID,
                isPinned: isPinned, workspaceID: workspaceID
            )
            dismiss()
        }
    }
}

private struct ManagementSheetScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let confirmTitle: String
    let canConfirm: Bool
    @ViewBuilder let content: Content
    let onConfirm: () -> Void

    init(
        title: String,
        confirmTitle: String,
        canConfirm: Bool,
        @ViewBuilder content: () -> Content,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.canConfirm = canConfirm
        self.content = content()
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: onConfirm)
                        .fontWeight(.semibold)
                        .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
