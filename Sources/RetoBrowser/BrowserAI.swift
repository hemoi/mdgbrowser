import AuthenticationServices
import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

enum BrowserAIProvider: String, Codable, CaseIterable, Identifiable {
    case chatGPT
    case claude
    case gemini
    case grok
    case perplexity
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .perplexity: "Perplexity"
        case .custom: "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .chatGPT: "sparkles"
        case .claude: "sun.max.fill"
        case .gemini: "sparkles"
        case .grok: "xmark"
        case .perplexity: "point.3.connected.trianglepath.dotted"
        case .custom: "link"
        }
    }

    var defaultURL: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/new")
        case .gemini: URL(string: "https://gemini.google.com/app")
        case .grok: URL(string: "https://grok.com/")
        case .perplexity: URL(string: "https://www.perplexity.ai/")
        case .custom: nil
        }
    }

    var iconURL: URL? {
        switch self {
        case .chatGPT:
            URL(string: "https://images.ctfassets.net/j22is2dtoxu1/intercom-img-d177d076c9a5453052925143/49d5d812b0a6fcc20a14faa8c629d9fb/icon-ios-1024_401x.png")
        case .claude:
            URL(string: "https://claude.ai/apple-touch-icon.png")
        case .gemini:
            URL(string: "https://www.gstatic.com/lamda/images/gemini_sparkle_4g_512_lt_f94943af3be039176192d.png")
        case .grok:
            URL(string: "https://grok.com/images/android-chrome-192x192.png")
        case .perplexity:
            URL(string: "https://www.perplexity.ai/apple-touch-icon.png")
        case .custom:
            nil
        }
    }

    static let quickAccessProviders: [BrowserAIProvider] = [
        .chatGPT, .claude, .gemini, .grok, .perplexity
    ]
}

struct BrowserAISettings: Codable, Equatable {
    var provider: BrowserAIProvider = .chatGPT
    var customName = ""
    var customURLString = ""
    var websiteDataStoreID = UUID()

    init(
        provider: BrowserAIProvider = .chatGPT,
        customName: String = "",
        customURLString: String = "",
        websiteDataStoreID: UUID = UUID()
    ) {
        self.provider = provider
        self.customName = customName
        self.customURLString = customURLString
        self.websiteDataStoreID = websiteDataStoreID
    }

    private enum CodingKeys: String, CodingKey {
        case provider, customName, customURLString, websiteDataStoreID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(BrowserAIProvider.self, forKey: .provider) ?? .chatGPT
        customName = try values.decodeIfPresent(String.self, forKey: .customName) ?? ""
        customURLString = try values.decodeIfPresent(String.self, forKey: .customURLString) ?? ""
        websiteDataStoreID = try values.decodeIfPresent(UUID.self, forKey: .websiteDataStoreID) ?? UUID()
    }

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

enum BrowserPasskeyAccessState: Equatable {
    case unavailable
    case notDetermined
    case authorized
    case denied

    var title: String {
        switch self {
        case .unavailable: "Unavailable on this device"
        case .notDetermined: "Not enabled"
        case .authorized: "Enabled"
        case .denied: "Blocked in Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable: "key.slash"
        case .notDetermined: "key"
        case .authorized: "key.fill"
        case .denied: "key.slash.fill"
        }
    }
}

@MainActor
@Observable
final class BrowserAIStore {
    static let defaultStorageKey = "reto-browser.ai-settings.v1"
    private static let maximumCachedSessions = 2

    var settings: BrowserAISettings
    var isPresented = false
    var settingsPresented = false
    var prompt = ""
    var statusMessage: String?
    private(set) var passkeyAccessState: BrowserPasskeyAccessState = .unavailable

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let contentBlocker = BrowserContentBlocker()
    @ObservationIgnored private let downloadManager = BrowserDownloadManager()
    @ObservationIgnored private let passkeyCredentialManager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    @ObservationIgnored private var sessionStorage: [BrowserAIProvider: BrowserSession] = [:]
    @ObservationIgnored private var sessionRecency: [BrowserAIProvider] = []

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = BrowserAIStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        settings = (defaults.data(forKey: storageKey))
            .flatMap { try? JSONDecoder().decode(BrowserAISettings.self, from: $0) }
            ?? BrowserAISettings()
        refreshPasskeyAccessState()
    }

    var session: BrowserSession {
        session(for: settings.provider)
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
        sessionStorage[settings.provider]?.stopLoading()
        settings.provider = provider
        persist()
        present()
    }

    @discardableResult
    func saveSettings(_ candidate: BrowserAISettings) -> Bool {
        guard candidate.provider != .custom || candidate.isCustomURLValid else {
            statusMessage = "Enter a valid http or https URL for the custom AI."
            return false
        }
        let customDestinationChanged = settings.customURLString != candidate.customURLString
        settings = candidate
        if customDestinationChanged {
            sessionStorage.removeValue(forKey: .custom)
            sessionRecency.removeAll(where: { $0 == .custom })
        }
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

    func refreshPasskeyAccessState() {
        passkeyAccessState = Self.passkeyState(
            from: passkeyCredentialManager.authorizationStateForPlatformCredentials
        )
    }

    func requestPasskeyAccess() {
        refreshPasskeyAccessState()
        switch passkeyAccessState {
        case .authorized:
            statusMessage = "Passkeys and iCloud Keychain are enabled for web sign-in."
        case .unavailable:
            statusMessage = "Set up passkeys in iCloud Keychain on this device first."
        case .denied:
            statusMessage = "Allow Reto Browser in Settings › Privacy & Security › Passkeys Access for Web Browsers."
        case .notDetermined:
            passkeyCredentialManager.requestAuthorizationForPublicKeyCredentials { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.passkeyAccessState = Self.passkeyState(from: state)
                    self.statusMessage = self.passkeyAccessState == .authorized
                        ? "Passkeys and iCloud Keychain are enabled for web sign-in."
                        : "Passkey access wasn’t enabled. You can change it later in Settings."
                }
            }
        }
    }

    private func session(for provider: BrowserAIProvider) -> BrowserSession {
        if let existing = sessionStorage[provider] {
            touchSession(provider)
            return existing
        }
        let session = makeSession(for: provider)
        sessionStorage[provider] = session
        touchSession(provider)
        trimSessionCache(keeping: provider)
        return session
    }

    private func makeSession(for provider: BrowserAIProvider) -> BrowserSession {
        let workspaceID = settings.websiteDataStoreID
        let destination = provider == .custom
            ? settings.effectiveURL
            : (provider.defaultURL ?? BrowserAIProvider.chatGPT.defaultURL!)
        let displayName = provider == .custom ? settings.displayName : provider.title
        let record = BrowserTabRecord(
            id: UUID(),
            title: "AI · \(displayName)",
            urlString: destination.absoluteString,
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
                if let url { self?.session(for: provider).open(url) }
                return nil
            },
            closeHandler: { [weak self] in self?.dismiss() }
        )
    }

    private func touchSession(_ provider: BrowserAIProvider) {
        sessionRecency.removeAll(where: { $0 == provider })
        sessionRecency.append(provider)
    }

    private func trimSessionCache(keeping provider: BrowserAIProvider) {
        while sessionStorage.count > Self.maximumCachedSessions,
              let candidate = sessionRecency.first(where: { $0 != provider }) {
            sessionStorage[candidate]?.stopLoading()
            sessionStorage.removeValue(forKey: candidate)
            sessionRecency.removeAll(where: { $0 == candidate })
        }
    }

    private static func passkeyState(
        from state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> BrowserPasskeyAccessState {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
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
            aiStore.refreshPasskeyAccessState()
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
        let providers = aiStore.settings.provider == .custom
            ? [.custom] + BrowserAIProvider.quickAccessProviders
            : BrowserAIProvider.quickAccessProviders

        return HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(providers) { provider in
                        providerButton(provider)
                    }
                }
            }
            .scrollClipDisabled()

            Spacer(minLength: 0)

            Button {
                aiStore.requestPasskeyAccess()
            } label: {
                Image(systemName: aiStore.passkeyAccessState.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(passkeyColor)
                    .frame(width: 34, height: 34)
                    .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Passkey access")
            .accessibilityValue(aiStore.passkeyAccessState.title)
            .accessibilityHint("Double tap to let websites use passkeys from iCloud Keychain and enabled password managers.")
            .accessibilityIdentifier("ai.passkeys")

            Button {
                aiStore.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI settings")
            .accessibilityIdentifier("ai.settings")

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

    private func providerButton(_ provider: BrowserAIProvider) -> some View {
        let selected = provider == aiStore.settings.provider

        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.24, extraBounce: 0.04)) {
                aiStore.activate(provider)
            }
        } label: {
            HStack(spacing: 5) {
                AIProviderIcon(provider: provider)

                if selected {
                    Text(provider == .custom ? aiStore.settings.displayName : provider.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .foregroundStyle(theme.label)
            .padding(.horizontal, selected ? 7 : 5)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? theme.label.opacity(0.09) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? theme.label.opacity(0.22) : Color.clear, lineWidth: 0.75)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(provider == .custom ? aiStore.settings.displayName : provider.title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("ai.provider.\(provider.rawValue)")
    }

    private var passkeyColor: Color {
        switch aiStore.passkeyAccessState {
        case .authorized: theme.tailnet
        case .denied: .red
        case .notDetermined, .unavailable: theme.label
        }
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

private struct AIProviderIcon: View {
    let provider: BrowserAIProvider

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white)

            if let iconURL = provider.iconURL {
                AsyncImage(
                    url: iconURL,
                    transaction: Transaction(animation: .easeOut(duration: 0.16))
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .empty:
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.black.opacity(0.55))
                    case .failure:
                        fallbackMark
                    @unknown default:
                        fallbackMark
                    }
                }
                .padding(2)
            } else {
                fallbackMark
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var fallbackMark: some View {
        Image(systemName: provider.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black)
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

                Section {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Password AutoFill")
                            Spacer()
                            Label("iCloud Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(theme.tailnet)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)

                        Divider()

                        Button {
                            aiStore.requestPasskeyAccess()
                        } label: {
                            HStack {
                                Label("Passkey access", systemImage: aiStore.passkeyAccessState.systemImage)
                                Spacer()
                                Text(aiStore.passkeyAccessState.title)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        }
                        .buttonStyle(.plain)

                        if aiStore.passkeyAccessState == .denied {
                            Divider()
                            Text("Enable Reto Browser in Settings › Privacy & Security › Passkeys Access for Web Browsers.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                } header: {
                    Text("Passwords & Passkeys")
                } footer: {
                    Text("WebKit asks iCloud Keychain or your enabled password manager for credentials. Reto stores website cookies and local site data in one persistent, isolated AI profile; it never copies your password into app settings.")
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
