import SwiftUI
import UIKit
import UserNotifications

final class RetoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct RetoBrowserApp: App {
    @UIApplicationDelegateAdaptor(RetoAppDelegate.self) private var appDelegate
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
