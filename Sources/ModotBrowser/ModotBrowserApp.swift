import SwiftUI

@main
struct ModotBrowserApp: App {
    @State private var theme = BrowserTheme()

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(theme)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Color.clear
        } else {
            BrowserView()
        }
    }
}
