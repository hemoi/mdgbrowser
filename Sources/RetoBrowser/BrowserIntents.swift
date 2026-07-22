import AppIntents
import Foundation

struct OpenWebsiteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Website"
    static let description = IntentDescription(
        "Opens a website or search in Reto Browser.",
        categoryName: "Browsing"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Website or search")
    var website: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$website)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = BrowserURL.resolve(website) else {
            throw OpenWebsiteError.invalidAddress
        }

        await MainActor.run {
            BrowserIntentRouter.shared.open(url)
        }

        return .result(dialog: "Opening \(url.host() ?? website) in Reto Browser.")
    }
}

struct RetoBrowserShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWebsiteIntent(),
            phrases: [
                "Open a website in \(.applicationName)",
                "Browse with \(.applicationName)",
            ],
            shortTitle: "Open Website",
            systemImageName: "safari"
        )
    }
}

private enum OpenWebsiteError: Error, CustomLocalizedStringResourceConvertible {
    case invalidAddress

    var localizedStringResource: LocalizedStringResource {
        "Enter a website or search term."
    }
}

