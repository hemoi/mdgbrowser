import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

enum BrowserAIProvider: String, Codable, CaseIterable, Identifiable {
    case chatGPT
    case claude
    case gemini
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .custom: "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .chatGPT: "sparkles"
        case .claude: "text.bubble"
        case .gemini: "diamond"
        case .custom: "link"
        }
    }

    var defaultURL: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/new")
        case .gemini: URL(string: "https://gemini.google.com/app")
        case .custom: nil
        }
    }
}

struct BrowserAISettings: Codable, Equatable {
    var provider: BrowserAIProvider = .chatGPT
    var customName = ""
    var customURLString = ""
    var websiteDataStoreID = UUID()

    var displayName: String {
        guard provider == .custom else { return provider.title }
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? provider.title : name
    }

    var effectiveURL: URL {
        if provider == .custom {
            return Self.validCustomURL(customURLString)
                ?? BrowserAIProvider.chatGPT.defaultURL!
        }
        return provider.defaultURL ?? BrowserAIProvider.chatGPT.defaultURL!
    }

    var isCustomURLValid: Bool {
        Self.validCustomURL(customURLString) != nil
    }

    static func validCustomURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}

@MainActor
@Observable
final class BrowserAIStore {
    static let defaultStorageKey = "modot-browser.ai-settings.v1"

    var settings: BrowserAISettings
    var isPresented = false
    var settingsPresented = false
    var prompt = ""
    var statusMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let contentBlocker = BrowserContentBlocker()
    @ObservationIgnored private let downloadManager = BrowserDownloadManager()
    @ObservationIgnored private var sessionStorage: BrowserSession?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = BrowserAIStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        settings = (defaults.data(forKey: storageKey))
            .flatMap { try? JSONDecoder().decode(BrowserAISettings.self, from: $0) }
            ?? BrowserAISettings()
    }

    var session: BrowserSession {
        if let sessionStorage { return sessionStorage }
        let session = makeSession()
        sessionStorage = session
        return session
    }

    func prepareWebFeatures() async {
        await contentBlocker.prepare()
    }

    func present() {
        isPresented = true
        let session = session
        if !session.hasLoaded {
            session.open(settings.effectiveURL)
        }
    }

    func dismiss() {
        isPresented = false
        statusMessage = nil
    }

    func activate(_ provider: BrowserAIProvider) {
        guard provider != .custom || settings.isCustomURLValid else {
            settingsPresented = true
            return
        }
        guard settings.provider != provider else {
            present()
            return
        }
        settings.provider = provider
        persist()
        sessionStorage = nil
        present()
    }

    @discardableResult
    func saveSettings(_ candidate: BrowserAISettings) -> Bool {
        guard candidate.provider != .custom || candidate.isCustomURLValid else {
            statusMessage = "Enter a valid http or https URL for the custom AI."
            return false
        }
        settings = candidate
        sessionStorage = nil
        persist()
        if isPresented {
            session.open(settings.effectiveURL)
        }
        statusMessage = nil
        return true
    }

    func insertCurrentPage(url: URL?, title: String) {
        guard let url else {
            statusMessage = "Open a webpage first."
            return
        }
        let pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = pageTitle.isEmpty ? "Review this page:" : "Review \(pageTitle):"
        prompt = "\(prefix) \(url.absoluteString)"
        statusMessage = "Page link added to the prompt."
    }

    func copyPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = trimmed
        statusMessage = "Prompt copied. Paste it into the AI chat."
    }

    private func makeSession() -> BrowserSession {
        let workspaceID = settings.websiteDataStoreID
        let record = BrowserTabRecord(
            id: UUID(),
            title: "AI · \(settings.displayName)",
            urlString: settings.effectiveURL.absoluteString,
            isPinned: true,
            groupID: nil
        )
        return BrowserSession(
            workspaceID: workspaceID,
            record: record,
            contentBlocker: contentBlocker,
            downloadManager: downloadManager,
            settingsProvider: { url in
                SiteSettingsRecord(
                    workspaceID: workspaceID,
                    host: url?.host()?.lowercased() ?? "",
                    blockerEnabled: false
                )
            },
            newWindowHandler: { [weak self] url, _ in
                if let url { self?.session.open(url) }
                return nil
            },
            closeHandler: { [weak self] in self?.dismiss() }
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct BrowserAIPanelHost: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let browserStore: WorkspaceBrowserStore
    let aiStore: BrowserAIStore

    var body: some View {
        GeometryReader { proxy in
            BrowserAIPanel(browserStore: browserStore, aiStore: aiStore)
                .frame(width: panelWidth(for: proxy.size), height: proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
        }
    }

    private func panelWidth(for size: CGSize) -> CGFloat {
        // Whole points: fractional widths make WKWebView re-raster on every
        // layout pass.
        if horizontalSizeClass == .compact {
            return min(size.width, max(320, size.width * 0.94)).rounded()
        }
        return min(size.width, min(440, max(360, size.width * 0.38))).rounded()
    }
}

private struct BrowserAIPanel: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let browserStore: WorkspaceBrowserStore
    let aiStore: BrowserAIStore

    var body: some View {
        @Bindable var aiStore = aiStore
        let session = aiStore.session

        VStack(spacing: 0) {
            panelHeader

            Divider()

            ZStack(alignment: .top) {
                AIWebView(session: session)
                    .id(session.instanceID)

                if session.isLoading {
                    ProgressView(value: session.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(theme.tailnet)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            promptComposer
        }
        .background(theme.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.border).frame(width: 0.5)
        }
        .accessibilityIdentifier("browser.ai.panel")
        .task(id: session.instanceID) {
            session.loadIfNeeded(fallbackURLString: aiStore.settings.effectiveURL.absoluteString)
        }
        .alert(
            "Couldn’t Open AI",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BrowserAIProvider.allCases) { provider in
                    Button {
                        aiStore.activate(provider)
                    } label: {
                        if provider == aiStore.settings.provider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Label(provider.title, systemImage: provider.systemImage)
                        }
                    }
                }
                Divider()
                Button("AI settings", systemImage: "gearshape") {
                    aiStore.settingsPresented = true
                }
            } label: {
                HStack(spacing: 5) {
                    Text(aiStore.settings.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.mutedLabel)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.label)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select AI provider")
            .accessibilityIdentifier("ai.settings")

            Spacer(minLength: 0)

            Button {
                withAnimation(reduceMotion ? .linear(duration: 0.14) : .snappy(duration: 0.24)) {
                    aiStore.dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close AI panel")
            .accessibilityIdentifier("ai.close")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var promptComposer: some View {
        @Bindable var aiStore = aiStore

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask about this page…", text: $aiStore.prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(theme.border, lineWidth: 0.75)
                    }
                    .accessibilityIdentifier("ai.prompt")

                composerButton(
                    systemName: "link.badge.plus",
                    label: "Insert current page",
                    disabled: browserStore.currentPageURL == nil
                ) {
                    aiStore.insertCurrentPage(
                        url: browserStore.currentPageURL,
                        title: browserStore.currentPageTitle
                    )
                }
                .accessibilityIdentifier("ai.current-page")

                composerButton(
                    systemName: "doc.on.doc",
                    label: "Copy AI prompt",
                    disabled: aiStore.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    aiStore.copyPrompt()
                }
                .accessibilityIdentifier("ai.copy-prompt")
            }

            if let statusMessage = aiStore.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(theme.mutedLabel)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(10)
        .background(theme.background)
    }

    private func composerButton(
        systemName: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 34, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(theme.border, lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

private struct AIWebView: UIViewRepresentable {
    let session: BrowserSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct BrowserAISettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BrowserTheme.self) private var theme
    @FocusState private var focusedField: Field?

    private enum Field {
        case customName
        case customURL
    }

    let aiStore: BrowserAIStore
    @State private var candidate: BrowserAISettings
    @State private var validationMessage: String?

    init(aiStore: BrowserAIStore) {
        self.aiStore = aiStore
        _candidate = State(initialValue: aiStore.settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Default AI") {
                    Picker("Chat app", selection: $candidate.provider) {
                        ForEach(BrowserAIProvider.allCases) { provider in
                            Label(provider.title, systemImage: provider.systemImage).tag(provider)
                        }
                    }

                    if candidate.provider != .custom {
                        LabeledContent("Chat URL", value: candidate.effectiveURL.absoluteString)
                            .font(.footnote)
                            .lineLimit(2)
                    }
                }

                if candidate.provider == .custom {
                    Section {
                        TextField("Name", text: $candidate.customName)
                            .focused($focusedField, equals: .customName)
                        TextField("https://chat.example.com", text: $candidate.customURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focusedField, equals: .customURL)
                    } header: {
                        Text("Custom AI")
                    } footer: {
                        Text("Use an http or https URL for a browser-based chat app.")
                    }
                }

                Section("Page handoff") {
                    Text("The Current page button only fills the local prompt. It is sent to the selected AI only after you copy and paste it into that chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard aiStore.saveSettings(candidate) else {
                            validationMessage = "Enter a valid custom AI URL."
                            return
                        }
                        dismiss()
                    }
                    .disabled(candidate.provider == .custom && !candidate.isCustomURLValid)
                }
            }
            .onChange(of: candidate.provider) {
                validationMessage = nil
                if candidate.provider == .custom {
                    focusedField = candidate.customName.isEmpty ? .customName : .customURL
                }
            }
        }
    }
}
