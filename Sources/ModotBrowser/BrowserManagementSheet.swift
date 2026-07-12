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
        case .pageNote:
            PageNoteSheet(store: store)
        case .pageTools:
            PageToolsSheet(store: store)
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
        ManagementSheetScaffold(title: "New workspace", confirmTitle: "Create", canConfirm: !trimmedName.isEmpty) {
            LabeledField(title: "Name", placeholder: "Work, Personal, Ops…", text: $name)
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
        ManagementSheetScaffold(title: "New group", confirmTitle: "Create", canConfirm: !trimmedName.isEmpty) {
            LabeledField(title: "Name", placeholder: "Tailnet, Dev tools…", text: $name)
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
    @State private var isPinned = true

    let store: WorkspaceBrowserStore

    init(store: WorkspaceBrowserStore, initialTitle: String, initialURL: String) {
        self.store = store
        _title = State(initialValue: initialTitle)
        _url = State(initialValue: initialURL)
        _groupID = State(initialValue: store.groups.first?.id)
    }

    var body: some View {
        ManagementSheetScaffold(title: "New bookmark", confirmTitle: "Save", canConfirm: BrowserURL.resolve(url) != nil) {
            VStack(spacing: 16) {
                LabeledField(title: "Name", placeholder: "Codex", text: $title)
                LabeledField(title: "Address", placeholder: "https://service.tailnet.ts.net", text: $url)

                VStack(alignment: .leading, spacing: 7) {
                    Text("GROUP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    Picker("Group", selection: $groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadcnField()
                }

                Toggle("Keep in command bar", isOn: $isPinned)
                    .font(.system(size: 13, weight: .medium))
            }
        } onConfirm: {
            store.addBookmark(title: title, urlString: url, groupID: groupID, isPinned: isPinned)
            dismiss()
        }
    }
}

private struct ManagementSheetScaffold<Content: View>: View {
    @Environment(BrowserTheme.self) private var theme
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
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(theme.mutedLabel)
            }

            content

            Spacer(minLength: 0)

            Button(confirmTitle, action: onConfirm)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.compactRadius))
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.35)
        }
        .padding(20)
        .background(theme.background)
    }
}

private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .shadcnField()
        }
    }
}
