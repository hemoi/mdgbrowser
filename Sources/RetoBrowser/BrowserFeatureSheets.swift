import QuickLook
import SwiftUI
import UIKit

struct CreateTabStackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let store: WorkspaceBrowserStore

    var body: some View {
        FeatureSheetScaffold(title: "New Tab Stack") {
            Form {
                Section {
                    TextField("Stack name", text: $name)
                        .textInputAutocapitalization(.sentences)
                }
            }
        } toolbar: {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    store.createTabStack(name: name)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .presentationDetents([.medium])
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
        FeatureSheetScaffold(title: settings.host.isEmpty ? "Site Settings" : settings.host) {
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

                Section("Privacy & Playback") {
                    Toggle("Block ads and trackers", isOn: $settings.blockerEnabled)
                    Toggle("Allow JavaScript", isOn: $settings.javaScriptEnabled)
                    Toggle("Allow autoplay", isOn: $settings.autoplayEnabled)
                }

                Section("Permissions") {
                    permissionPicker("Camera", selection: $settings.cameraPermission)
                    permissionPicker("Microphone", selection: $settings.microphonePermission)
                }

                Section {
                    Button("Clear This Site’s Data", role: .destructive) {
                        store.clearCurrentSiteData()
                    }
                    Button("Clear All Data in This Workspace", role: .destructive) {
                        store.clearActiveWorkspaceData()
                    }
                } footer: {
                    Text("Cookies, cache and local storage are isolated per workspace.")
                }
            }
        } toolbar: {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save and Reload") {
                    store.saveSiteSettings(settings)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(settings.host.isEmpty)
            }
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

struct PageToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var resultMessage = ""
    @State private var exporting = false
    let store: WorkspaceBrowserStore

    var body: some View {
        let session = store.session(for: store.activePane)
        FeatureSheetScaffold(title: "Page Tools") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        TextField("Find on page", text: $query)
                            .textFieldStyle(.roundedBorder)
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
                .padding(16)
            }
        } toolbar: {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
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

struct BrowserDeveloperToolsSheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var panel = DeveloperPanel.console
    @State private var snapshot = DeveloperSnapshot.empty
    @State private var command = "document.title"
    @State private var evaluationResult = ""
    @State private var errorMessage = ""
    @State private var refreshing = false
    @State private var logSelection = DeveloperConsoleSelection()
    @State private var copyStatus = ""

    let store: WorkspaceBrowserStore

    var body: some View {
        let session = store.session(for: store.activePane)

        FeatureSheetScaffold(title: "Developer Tools · \(store.currentPageTitle)") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Panel", selection: $panel) {
                        ForEach(DeveloperPanel.allCases) { panel in
                            Label(panel.label, systemImage: panel.systemName).tag(panel)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task { await refresh(session) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(refreshing)
                    .accessibilityLabel("Refresh developer data")
                }
                .padding(10)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                Divider()

                switch panel {
                case .console:
                    consolePanel(session)
                case .dom:
                    domPanel
                case .network:
                    networkPanel
                case .javascript:
                    javascriptPanel(session)
                }
            }
        } toolbar: {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await refresh(session) }
        .onChange(of: copyStatus) {
            guard !copyStatus.isEmpty else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                copyStatus = ""
            }
        }
    }

    private func consolePanel(_ session: BrowserSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(copyStatus.isEmpty ? "\(snapshot.logs.count) messages" : copyStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedLabel)
                    .lineLimit(1)
                Spacer()
                if !logSelection.isEmpty {
                    Button("Deselect") { logSelection.clear() }
                }
                Button(logSelection.isEmpty ? "Copy" : "Copy (\(logSelection.count))") {
                    copySelectedLogs()
                }
                .disabled(logSelection.isEmpty)
                .accessibilityLabel("Copy \(logSelection.count) selected logs")
                Button("Clear", role: .destructive) {
                    Task {
                        do {
                            try await session.clearDeveloperConsole()
                            await refresh(session)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            if snapshot.logs.isEmpty {
                ContentUnavailableView("No console messages", systemImage: "terminal")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.logs.enumerated()), id: \.offset) { index, entry in
                            consoleRow(index: index, entry: entry)
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func consoleRow(index: Int, entry: DeveloperConsoleEntry) -> some View {
        let id = DeveloperConsoleLogID(index: index, entry: entry)
        let isSelected = logSelection.isSelected(id)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? theme.accent : theme.mutedLabel.opacity(0.5))
                .frame(width: 14, height: 16)
            Image(systemName: entry.systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry.color)
                .frame(width: 12, height: 16)
            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.timeLabel)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(theme.mutedLabel)
            Menu {
                Button("Copy message", systemImage: "doc.on.doc") { copyLog(entry) }
                Button(isSelected ? "Deselect" : "Select",
                       systemImage: isSelected ? "circle" : "checkmark.circle") {
                    logSelection.toggle(id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.mutedLabel)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Log actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? theme.accent.opacity(0.08)
                : entry.level == "error" ? Color.red.opacity(0.06) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { logSelection.toggle(id) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func copySelectedLogs() {
        guard let text = logSelection.copyText(from: snapshot.logs) else {
            copyStatus = "Tap logs to select them first"
            return
        }
        UIPasteboard.general.string = text
        copyStatus = "Copied \(logSelection.count) \(logSelection.count == 1 ? "log" : "logs")"
    }

    private func copyLog(_ entry: DeveloperConsoleEntry) {
        UIPasteboard.general.string = entry.message
        copyStatus = "Log message copied"
    }

    private var domPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(snapshot.url)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.mutedLabel)
                    .lineLimit(1)
                Spacer()
                Text("\(snapshot.dom.count) chars")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.mutedLabel)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            Divider()

            TextEditor(text: .constant(snapshot.dom))
                .font(.system(size: 10, design: .monospaced))
                .autocorrectionDisabled()
                .padding(6)
        }
    }

    private var networkPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(snapshot.resources.count) resources")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedLabel)
                Spacer()
                Text("Resource Timing")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedLabel)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            Divider()

            if snapshot.resources.isEmpty {
                ContentUnavailableView("No resource timing data", systemImage: "network")
            } else {
                List(snapshot.resources.reversed()) { resource in
                    HStack(spacing: 10) {
                        Text(resource.initiatorType.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.mutedLabel)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Text(resource.detailLabel)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(theme.mutedLabel)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func javascriptPanel(_ session: BrowserSession) -> some View {
        VStack(spacing: 10) {
            TextEditor(text: $command)
                .font(.system(size: 11, design: .monospaced))
                .autocorrectionDisabled()
                .padding(6)
                .frame(minHeight: 110)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("Runs in the current page")
                    .font(.caption)
                    .foregroundStyle(theme.mutedLabel)
                Spacer()
                Button("Run", systemImage: "play.fill") {
                    Task { await evaluate(session) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            ScrollView {
                Text(evaluationResult.isEmpty ? "Result appears here." : evaluationResult)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(evaluationResult.isEmpty ? theme.mutedLabel : theme.label)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
    }

    private func refresh(_ session: BrowserSession) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let data = Data(try await session.developerSnapshotJSON().utf8)
            var decoded = try JSONDecoder().decode(DeveloperSnapshot.self, from: data)
            if decoded.dom.count > 750_000 {
                decoded.dom = String(decoded.dom.prefix(750_000)) + "\n<!-- Truncated by Reto Browser -->"
            }
            snapshot = decoded
            logSelection.reconcile(with: decoded.logs)
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func evaluate(_ session: BrowserSession) async {
        do {
            evaluationResult = try await session.runDeveloperScript(command)
            errorMessage = ""
            await refresh(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum DeveloperPanel: String, CaseIterable, Identifiable {
    case console, dom, network, javascript

    var id: Self { self }
    var label: String {
        switch self {
        case .console: "Console"
        case .dom: "DOM"
        case .network: "Network"
        case .javascript: "JS"
        }
    }
    var systemName: String {
        switch self {
        case .console: "terminal"
        case .dom: "chevron.left.forwardslash.chevron.right"
        case .network: "network"
        case .javascript: "play.rectangle"
        }
    }
}

private struct DeveloperSnapshot: Decodable {
    var url: String
    var title: String
    var dom: String
    var logs: [DeveloperConsoleEntry]
    var resources: [DeveloperResourceEntry]

    static let empty = DeveloperSnapshot(url: "", title: "", dom: "", logs: [], resources: [])
}

private extension DeveloperConsoleEntry {
    var systemName: String {
        switch level {
        case "error": "xmark.octagon.fill"
        case "warn": "exclamationmark.triangle.fill"
        case "info": "info.circle.fill"
        default: "chevron.right"
        }
    }
    var color: Color {
        switch level {
        case "error": .red
        case "warn": .orange
        case "info": .blue
        default: .secondary
        }
    }
}

private struct DeveloperResourceEntry: Decodable, Identifiable {
    var id: String { "\(name)-\(duration)-\(transferSize)" }
    let name: String
    let initiatorType: String
    let duration: Double
    let transferSize: Double

    var detailLabel: String {
        let bytes = transferSize > 0 ? ByteCountFormatter.string(fromByteCount: Int64(transferSize), countStyle: .file) : "cached/unknown"
        return "\(duration.formatted(.number.precision(.fractionLength(1)))) ms · \(bytes)"
    }
}

struct TabArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: WorkspaceBrowserStore

    var body: some View {
        FeatureSheetScaffold(title: "Tab History") {
            List {
                Section("Recently Closed") {
                    if store.recentlyClosedTabs.isEmpty {
                        ContentUnavailableView("No recently closed tabs", systemImage: "clock.arrow.circlepath")
                    }
                    ForEach(store.recentlyClosedTabs) { stored in
                        storedTabRow(stored) { store.restoreClosedTab(stored.id) }
                    }
                }

                Section("Auto Archive") {
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
        } toolbar: {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
    @Environment(\.dismiss) private var dismiss
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
        } toolbar: {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear", role: .destructive) { store.downloadManager.clearFinished() }
                    .disabled(!store.downloadManager.records.contains(where: { $0.state != .downloading }))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
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

private struct FeatureSheetScaffold<Content: View, SheetToolbar: ToolbarContent>: View {
    let title: String
    @ViewBuilder let content: Content
    @ToolbarContentBuilder let toolbar: SheetToolbar

    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ToolbarContentBuilder toolbar: () -> SheetToolbar
    ) {
        self.title = title
        self.content = content()
        self.toolbar = toolbar()
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
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
