import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let instanceID = UUID()
    let workspaceID: UUID
    let webView: WKWebView

    var address: String
    var errorMessage: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var title = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = true
    private(set) var readerStyleEnabled = false
    private(set) var autoScrollEnabled = false

    @ObservationIgnored private let contentBlocker: BrowserContentBlocker
    @ObservationIgnored private let downloadManager: BrowserDownloadManager
    @ObservationIgnored private let settingsProvider: (URL?) -> SiteSettingsRecord
    @ObservationIgnored private let newWindowHandler: (URL?, WKWebViewConfiguration) -> WKWebView?
    @ObservationIgnored private let closeHandler: () -> Void
    @ObservationIgnored private var blockerInstalled = false
    @ObservationIgnored private var autoScrollTask: Task<Void, Never>?

    init(
        workspaceID: UUID,
        record: BrowserTabRecord,
        contentBlocker: BrowserContentBlocker,
        downloadManager: BrowserDownloadManager,
        settingsProvider: @escaping (URL?) -> SiteSettingsRecord,
        webViewConfiguration: WKWebViewConfiguration? = nil,
        startsLoaded: Bool = false,
        newWindowHandler: @escaping (URL?, WKWebViewConfiguration) -> WKWebView?,
        closeHandler: @escaping () -> Void
    ) {
        id = record.id
        self.workspaceID = workspaceID
        self.contentBlocker = contentBlocker
        self.downloadManager = downloadManager
        self.settingsProvider = settingsProvider
        self.newWindowHandler = newWindowHandler
        self.closeHandler = closeHandler
        hasLoaded = startsLoaded
        address = record.urlString == StartPage.url.absoluteString ? "" : record.urlString

        let configuration = webViewConfiguration ?? WKWebViewConfiguration()
        if webViewConfiguration == nil {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: workspaceID)
        }
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.allowsInlineMediaPlayback = true

        let initialURL = BrowserURL.resolve(record.urlString)
        let initialSettings = settingsProvider(initialURL)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = initialSettings.javaScriptEnabled
        configuration.defaultWebpagePreferences.preferredContentMode = initialSettings.contentMode.webKitValue
        configuration.mediaTypesRequiringUserActionForPlayback = initialSettings.autoplayEnabled ? [] : .all

        if webViewConfiguration == nil {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.developerInstrumentationScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        if let ruleList = contentBlocker.ruleList {
            // A popup configuration can inherit the opener's content controller.
            // Normalize it before applying the destination site's setting.
            configuration.userContentController.remove(ruleList)
            if initialSettings.blockerEnabled {
                configuration.userContentController.add(ruleList)
                blockerInstalled = true
            }
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        applyVisualSettings(for: initialURL)
    }

    func loadIfNeeded(fallbackURLString: String) {
        guard !hasLoaded else { return }
        hasLoaded = true

        if fallbackURLString == StartPage.url.absoluteString {
            webView.loadHTMLString(StartPage.html, baseURL: StartPage.url)
        } else if let url = BrowserURL.resolve(fallbackURLString) {
            open(url)
        }
    }

    func openAddress() -> URL? {
        guard let url = BrowserURL.resolve(address) else {
            errorMessage = "Enter a website or search term."
            return nil
        }
        open(url)
        return url
    }

    func open(_ url: URL) {
        hasLoaded = true
        address = url.absoluteString
        errorMessage = nil
        readerStyleEnabled = false
        applySiteSettings(for: url)
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func reloadWithoutCache() { webView.reloadFromOrigin() }

    func stopLoading() {
        webView.stopLoading()
        isLoading = false
    }

    func toggleAutoScroll() {
        setAutoScrollEnabled(!autoScrollEnabled)
    }

    func setAutoScrollEnabled(_ enabled: Bool) {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollEnabled = enabled
        guard enabled else { return }

        autoScrollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let shouldContinue: Bool
                do {
                    guard let self else { return }
                    shouldContinue = advanceAutoScroll()
                }
                guard shouldContinue else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func advanceAutoScroll() -> Bool {
        let scrollView = webView.scrollView
        guard !scrollView.isDragging, !scrollView.isDecelerating else { return true }

        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let currentY = scrollView.contentOffset.y

        guard currentY < maximumY - 0.5 else {
            autoScrollEnabled = false
            autoScrollTask = nil
            return false
        }

        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: min(currentY + 1.25, maximumY)),
            animated: false
        )
        return true
    }

    func applyCurrentSiteSettings(reload: Bool = true) {
        applySiteSettings(for: currentURL ?? BrowserURL.resolve(address))
        if reload, hasLoaded { webView.reloadFromOrigin() }
    }

    func find(_ query: String, backwards: Bool = false) async -> Bool {
        guard !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        do {
            return try await webView.find(query, configuration: configuration).matchFound
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func developerSnapshotJSON() async throws -> String {
        let result = try await webView.evaluateJavaScript(Self.developerSnapshotScript)
        guard let json = result as? String else { throw BrowserSessionError.developerSnapshotFailed }
        return json
    }

    func runDeveloperScript(_ script: String) async throws -> String {
        guard let result = try await webView.evaluateJavaScript(script) else { return "undefined" }
        if let string = result as? String { return string }
        if JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: result)
    }

    func clearDeveloperConsole() async throws {
        _ = try await webView.evaluateJavaScript("window.__modotDevtools && (window.__modotDevtools.logs = [])")
    }

    func toggleReaderStyle() {
        let script = readerStyleEnabled ? Self.disableReaderScript : Self.enableReaderScript
        readerStyleEnabled.toggle()
        webView.evaluateJavaScript(script, completionHandler: { [weak self] _, error in
            if let error { self?.errorMessage = error.localizedDescription }
        })
    }

    func exportPDF() async throws -> URL {
        let data = try await webView.pdf()
        let destination = Self.uniqueExportURL(title: title, extension: "pdf")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func exportSnapshot() async throws -> URL {
        let configuration = WKSnapshotConfiguration()
        let contentSize = webView.scrollView.contentSize
        if contentSize.width > 0, contentSize.height > 0, contentSize.height < 16_000 {
            configuration.rect = CGRect(origin: .zero, size: contentSize)
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let data = image.pngData() else { throw BrowserSessionError.snapshotEncodingFailed }
        let destination = Self.uniqueExportURL(title: title, extension: "png")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let url = navigationAction.request.url
        if let url,
           let scheme = url.scheme?.lowercased(),
           !Self.webViewSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        let settings = settingsProvider(url)
        preferences.allowsContentJavaScript = settings.javaScriptEnabled
        preferences.preferredContentMode = settings.contentMode.webKitValue
        applySiteSettings(for: url)
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadManager.attach(download, sourceURL: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadManager.attach(download, sourceURL: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        estimatedProgress = 0.12
        readerStyleEnabled = false
        refreshPageState(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        estimatedProgress = max(estimatedProgress, 0.58)
        refreshPageState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        estimatedProgress = 1
        isLoading = false
        refreshPageState(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        handleFailure(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        handleFailure(error, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return newWindowHandler(navigationAction.request.url, configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closeHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let presenter = Self.presentingViewController(for: webView) else {
            completionHandler()
            return
        }
        let alert = UIAlertController(
            title: Self.dialogTitle(for: frame),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard let presenter = Self.presentingViewController(for: webView) else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(
            title: Self.dialogTitle(for: frame),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard let presenter = Self.presentingViewController(for: webView) else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(
            title: Self.dialogTitle(for: frame),
            message: prompt,
            preferredStyle: .alert
        )
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = origin.host
        let settings = settingsProvider(components.url)
        let permission: BrowserPermission
        switch type {
        case .camera:
            permission = settings.cameraPermission
        case .microphone:
            permission = settings.microphonePermission
        case .cameraAndMicrophone:
            permission = settings.cameraPermission == .deny || settings.microphonePermission == .deny
                ? .deny
                : (settings.cameraPermission == .allow && settings.microphonePermission == .allow ? .allow : .ask)
        @unknown default:
            permission = .ask
        }
        decisionHandler(permission.webKitValue)
    }

    private func applySiteSettings(for url: URL?) {
        let settings = settingsProvider(url)
        applyVisualSettings(for: url)
        let controller = webView.configuration.userContentController
        if settings.blockerEnabled, let ruleList = contentBlocker.ruleList, !blockerInstalled {
            controller.add(ruleList)
            blockerInstalled = true
        } else if !settings.blockerEnabled, blockerInstalled, let ruleList = contentBlocker.ruleList {
            controller.remove(ruleList)
            blockerInstalled = false
        }
    }

    private func applyVisualSettings(for url: URL?) {
        let settings = settingsProvider(url)
        webView.pageZoom = CGFloat(min(max(settings.pageZoom, 0.5), 2))
    }

    private func handleFailure(_ error: any Error, webView: WKWebView) {
        isLoading = false
        refreshPageState(from: webView)
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    private func refreshPageState(from webView: WKWebView) {
        let url = webView.url
        currentURL = url?.host == StartPage.url.host ? nil : url
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        hasOnlySecureContent = webView.hasOnlySecureContent
        if let currentURL { address = currentURL.absoluteString }
    }

    private static let webViewSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "modot-start"
    ]

    private static func dialogTitle(for frame: WKFrameInfo) -> String {
        frame.request.url?.host().map { "\($0) says" } ?? "This webpage says"
    }

    private static func presentingViewController(for webView: WKWebView) -> UIViewController? {
        guard var controller = webView.window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        if let navigation = controller as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }
        if let tab = controller as? UITabBarController {
            return tab.selectedViewController ?? tab
        }
        return controller
    }

    private static func uniqueExportURL(title: String, extension fileExtension: String) -> URL {
        try? FileManager.default.createDirectory(
            at: BrowserDownloadManager.downloadsDirectory,
            withIntermediateDirectories: true
        )
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let base = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = base.isEmpty ? "Page" : base
        return BrowserDownloadManager.downloadsDirectory
            .appendingPathComponent("\(fileName)-\(Int(Date().timeIntervalSince1970)).\(fileExtension)")
    }

    private static let developerInstrumentationScript = #"""
    (() => {
      if (window.__modotDevtools) return;
      const state = { logs: [] };
      const render = value => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack || value.message;
        if (typeof value === 'undefined') return 'undefined';
        if (typeof value === 'function') return value.toString();
        try {
          const seen = new WeakSet();
          return JSON.stringify(value, (_key, nested) => {
            if (typeof nested === 'bigint') return `${nested}n`;
            if (nested && typeof nested === 'object') {
              if (seen.has(nested)) return '[Circular]';
              seen.add(nested);
            }
            return nested;
          });
        } catch (_) {
          return String(value);
        }
      };
      const push = (level, values) => {
        state.logs.push({
          level,
          message: Array.from(values).map(render).join(' '),
          timestamp: Date.now()
        });
        if (state.logs.length > 500) state.logs.splice(0, state.logs.length - 500);
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level]?.bind(console);
        console[level] = (...values) => {
          push(level, values);
          if (original) original(...values);
        };
      }
      window.addEventListener('error', event => {
        push('error', [event.message, event.filename ? `(${event.filename}:${event.lineno})` : '']);
      });
      window.addEventListener('unhandledrejection', event => {
        push('error', ['Unhandled promise rejection:', event.reason]);
      });
      window.__modotDevtools = state;
    })();
    """#

    private static let developerSnapshotScript = #"""
    (() => JSON.stringify({
      url: location.href,
      title: document.title,
      dom: document.documentElement ? document.documentElement.outerHTML : '',
      logs: (window.__modotDevtools && window.__modotDevtools.logs) || [],
      resources: performance.getEntriesByType('resource').slice(-500).map(entry => ({
        name: entry.name,
        initiatorType: entry.initiatorType || 'other',
        duration: entry.duration || 0,
        transferSize: entry.transferSize || 0
      }))
    }))()
    """#

    private static let enableReaderScript = #"""
    (() => {
      if (document.getElementById('modot-reader-style')) return true;
      const style = document.createElement('style');
      style.id = 'modot-reader-style';
      style.textContent = `
        body { max-width: 760px !important; margin: 0 auto !important; padding: 48px 24px !important;
               font: 19px/1.75 -apple-system, BlinkMacSystemFont, sans-serif !important;
               background: #fff !important; color: #171717 !important; }
        header, nav, aside, footer, [role=banner], [role=navigation], iframe, .ad, .ads { display:none !important; }
        article, main { display:block !important; max-width:none !important; }
        img, video { max-width:100% !important; height:auto !important; }
        p { margin: 0 0 1.25em !important; }
      `;
      document.head.appendChild(style);
      return true;
    })()
    """#

    private static let disableReaderScript = #"""
    (() => { document.getElementById('modot-reader-style')?.remove(); return true; })()
    """#
}

private enum BrowserSessionError: LocalizedError {
    case snapshotEncodingFailed
    case developerSnapshotFailed

    var errorDescription: String? {
        switch self {
        case .snapshotEncodingFailed: "The page snapshot could not be encoded."
        case .developerSnapshotFailed: "The page did not return developer information."
        }
    }
}

private extension BrowserContentMode {
    var webKitValue: WKWebpagePreferences.ContentMode {
        switch self {
        case .recommended: .recommended
        case .mobile: .mobile
        case .desktop: .desktop
        }
    }
}

private extension BrowserPermission {
    var webKitValue: WKPermissionDecision {
        switch self {
        case .ask: .prompt
        case .allow: .grant
        case .deny: .deny
        }
    }
}
