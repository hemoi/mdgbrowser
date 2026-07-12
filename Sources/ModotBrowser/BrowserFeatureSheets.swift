import QuickLook
import SwiftUI

struct CreateTabStackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let store: WorkspaceBrowserStore

    var body: some View {
        FeatureSheetScaffold(title: "New tab stack") {
            TextField("Stack name", text: $name)
                .textInputAutocapitalization(.sentences)
                .shadcnField()
        } footer: {
            Button("Create") {
                store.createTabStack(name: name)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct SiteSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: SiteSettingsRecord
    let store: WorkspaceBrowserStore

    init(store: WorkspaceBrowserStore) {
        self.store = store
        _settings = State(initialValue: store.settings(for: store.currentPageURL))
    }

    var body: some View {
        FeatureSheetScaffold(title: settings.host.isEmpty ? "Site settings" : settings.host) {
            Form {
                Section("Rendering") {
                    Picker("Content mode", selection: $settings.contentMode) {
                        ForEach(BrowserContentMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    Slider(value: $settings.pageZoom, in: 0.5...2, step: 0.1) {
                        Text("Page zoom")
                    } minimumValueLabel: {
                        Text("50%")
                    } maximumValueLabel: {
                        Text("200%")
                    }
                    Text("Zoom \(Int(settings.pageZoom * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy & playback") {
                    Toggle("Block ads and trackers", isOn: $settings.blockerEnabled)
                    Toggle("Allow JavaScript", isOn: $settings.javaScriptEnabled)
                    Toggle("Allow autoplay", isOn: $settings.autoplayEnabled)
                }

                Section("Permissions") {
                    permissionPicker("Camera", selection: $settings.cameraPermission)
                    permissionPicker("Microphone", selection: $settings.microphonePermission)
                }

                Section {
                    Button("Clear this site’s data", role: .destructive) {
                        store.clearCurrentSiteData()
                    }
                    Button("Clear all data in this workspace", role: .destructive) {
                        store.clearActiveWorkspaceData()
                    }
                } footer: {
                    Text("Cookies, cache and local storage are isolated per workspace.")
                }
            }
            .scrollContentBackground(.hidden)
        } footer: {
            Button("Save and reload") {
                store.saveSiteSettings(settings)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(settings.host.isEmpty)
        }
    }

    private func permissionPicker(_ title: String, selection: Binding<BrowserPermission>) -> some View {
        Picker(title, selection: selection) {
            ForEach(BrowserPermission.allCases) { permission in
                Text(permission.label).tag(permission)
            }
        }
    }
}

struct PageNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let store: WorkspaceBrowserStore

    init(store: WorkspaceBrowserStore) {
        self.store = store
        _text = State(initialValue: store.currentPageNote?.text ?? "")
    }

    var body: some View {
        FeatureSheetScaffold(title: "Page note") {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.currentPageTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(store.currentPageURL?.absoluteString ?? "Start page")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5) }
                    .frame(minHeight: 80)
                    .accessibilityLabel("Page note text")
            }
        } footer: {
            Button("Save") {
                store.saveCurrentPageNote(text)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct PageToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var resultMessage = ""
    @State private var exporting = false
    let store: WorkspaceBrowserStore

    var body: some View {
        let session = store.session(for: store.activePane)
        FeatureSheetScaffold(title: "Page tools") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        TextField("Find on page", text: $query)
                            .shadcnField()
                            .submitLabel(.search)
                            .onSubmit { find(backwards: false, session: session) }
                        Button { find(backwards: true, session: session) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.bordered)
                        Button { find(backwards: false, session: session) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !resultMessage.isEmpty {
                        Text(resultMessage).font(.caption).foregroundStyle(.secondary)
                    }

                    toolGrid(session: session)

                    if exporting { ProgressView("Creating file…") }
                }
            }
        } footer: {
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func toolGrid(session: BrowserSession) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            toolButton(session.readerStyleEnabled ? "Exit reader" : "Reader style", icon: "text.alignleft") {
                session.toggleReaderStyle()
            }
            toolButton("Translate to Korean", icon: "character.bubble") {
                guard let source = store.currentPageURL,
                      var components = URLComponents(string: "https://translate.google.com/translate") else { return }
                components.queryItems = [
                    URLQueryItem(name: "sl", value: "auto"),
                    URLQueryItem(name: "tl", value: "ko"),
                    URLQueryItem(name: "u", value: source.absoluteString)
                ]
                if let url = components.url { store.open(url) }
                dismiss()
            }
            toolButton("Save PDF", icon: "doc.richtext") { exportPDF(session) }
            toolButton("Full screenshot", icon: "camera.viewfinder") { exportSnapshot(session) }
            toolButton("Reload without cache", icon: "arrow.clockwise") {
                session.reloadWithoutCache()
                dismiss()
            }
            toolButton("Share page", icon: "square.and.arrow.up") {
                store.shareCurrentPage()
                dismiss()
            }
        }
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.bordered)
        .disabled(exporting)
    }

    private func find(backwards: Bool, session: BrowserSession) {
        Task {
            resultMessage = await session.find(query, backwards: backwards) ? "Match found" : "No match"
        }
    }

    private func exportPDF(_ session: BrowserSession) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                store.registerGeneratedDownload(try await session.exportPDF())
                resultMessage = "PDF saved to Downloads"
            } catch { resultMessage = error.localizedDescription }
        }
    }

    private func exportSnapshot(_ session: BrowserSession) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                store.registerGeneratedDownload(try await session.exportSnapshot())
                resultMessage = "Screenshot saved to Downloads"
            } catch { resultMessage = error.localizedDescription }
        }
    }
}

struct TabArchiveSheet: View {
    let store: WorkspaceBrowserStore

    var body: some View {
        FeatureSheetScaffold(title: "Tab history") {
            List {
                Section("Recently closed") {
                    if store.recentlyClosedTabs.isEmpty {
                        ContentUnavailableView("No recently closed tabs", systemImage: "clock.arrow.circlepath")
                    }
                    ForEach(store.recentlyClosedTabs) { stored in
                        storedTabRow(stored) { store.restoreClosedTab(stored.id) }
                    }
                }

                Section("Auto archive") {
                    Stepper(
                        store.autoArchiveAfterDays == 0 ? "Automatic archive off" : "After \(store.autoArchiveAfterDays) days",
                        value: Binding(
                            get: { store.autoArchiveAfterDays },
                            set: { store.autoArchiveAfterDays = $0; store.autoArchiveStaleTabs() }
                        ),
                        in: 0...90
                    )
                    if store.archivedTabs.isEmpty {
                        ContentUnavailableView("No archived tabs", systemImage: "archivebox")
                    }
                    ForEach(store.archivedTabs) { stored in
                        storedTabRow(stored) { store.restoreArchivedTab(stored.id) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.deleteArchivedTab(stored.id) }
                            }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } footer: { EmptyView() }
    }

    private func storedTabRow(_ stored: StoredTabRecord, restore: @escaping () -> Void) -> some View {
        Button(action: restore) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stored.tab.title).foregroundStyle(.primary).lineLimit(1)
                Text(stored.tab.urlString).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct DownloadsSheet: View {
    @State private var preview: PreviewFile?
    let store: WorkspaceBrowserStore

    var body: some View {
        FeatureSheetScaffold(title: "Downloads") {
            List {
                if store.downloadManager.records.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
                }
                ForEach(store.downloadManager.records) { record in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: record.state))
                            .foregroundStyle(color(for: record.state))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.fileName).lineLimit(1)
                            Text(record.errorMessage ?? record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if record.state == .downloading { ProgressView() }
                        if let url = record.localURL, record.state == .completed {
                            Button { preview = PreviewFile(url: url) } label: { Image(systemName: "eye") }
                            Button { store.sharePayload = SharePayload(url: url) } label: { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.downloadManager.delete(record.id) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Button("Clear finished", role: .destructive) { store.downloadManager.clearFinished() }
                .disabled(!store.downloadManager.records.contains(where: { $0.state != .downloading }))
        }
        .sheet(item: $preview) { QuickLookPreview(url: $0.url) }
    }

    private func icon(for state: BrowserDownloadState) -> String {
        switch state {
        case .downloading: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for state: BrowserDownloadState) -> Color {
        switch state {
        case .downloading: .accentColor
        case .completed: .green
        case .failed: .red
        }
    }
}

private struct FeatureSheetScaffold<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)

            if Footer.self != EmptyView.self {
                Divider()
                HStack { Spacer(); footer }
                    .padding(16)
            }
        }
    }
}

private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
