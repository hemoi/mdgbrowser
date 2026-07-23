# TestFlight delivery

`main` is the release branch. GitHub Actions runs the `iOS CI` simulator test job for every pull request and every `main` push. Xcode Cloud is the distribution authority: it runs a second test action, archives the app, and publishes the archive to TestFlight only when those Xcode Cloud actions succeed.

## One-time Xcode Cloud setup

1. In Xcode, sign in with an Apple Account that has an App Store Connect `App Manager`, `Admin`, or `Account Holder` role for team `Q3N5A977S4`.
2. Open `RetoBrowser.xcodeproj`. The shared `RetoBrowser` scheme and its Archive action are already present, and Release signing is configured for automatic management.
3. Choose **Integrate > Create Workflow**. Grant the Apple Xcode Cloud GitHub App access only to `hemoi/mdgbrowser`.
4. Create a workflow named `TestFlight (main)` with these settings:
   - Start condition: branch changes on `main`.
   - Test action: `RetoBrowser` on the latest iOS simulator, iPhone 17 Pro.
   - Archive action: iOS, `RetoBrowser` scheme, Release configuration.
   - Post-action: distribute the archive to the intended internal TestFlight tester group.
5. Start the first build from Xcode. After it succeeds, the next `main` push automatically creates the next TestFlight build.

Xcode Cloud assigns an increasing build number to each build. Keep `MARKETING_VERSION` at the intended release version; increase it before a new App Store version is submitted.

## GitHub protection

After the first `iOS CI` run is green, protect `main` and require the `iOS CI / test` check before merging pull requests. Xcode Cloud remains responsible for signing, archiving, and TestFlight upload, so no Apple certificates or App Store Connect keys are stored in GitHub.
