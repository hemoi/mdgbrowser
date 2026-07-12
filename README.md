# Modot Browser

A minimal service browser for iPad and iPhone, built with SwiftUI, independent `WKWebView` tab sessions, and App Intents.

## Features

- Persistent workspaces with compact, pinnable tabs
- Adjustable left/right WebView split
- Tailnet-friendly bookmark groups and pinned services
- A responsive command bar: one row on iPad and two touch-friendly rows on iPhone
- A hamburger sidebar for workspace, group, pin, and bookmark management
- A deterministic offline start page with no fake service addresses
- A bundled animated Banana pet with reload/new-tab shortcuts, draggable positioning, and persistent size controls
- An **Open Website** App Shortcut for Siri, Spotlight, and Shortcuts
- First-class SSH connections in the sidebar, command bar, and command palette
- `ssh://user@host:port` address import plus a draggable iPad terminal and a resizable, dismissible iPhone sheet
- Multiple concurrent SSH terminal tabs, optional tmux attach/create, and pinned host-key verification
- Password (including keyboard-interactive/PAM fallback) or imported Ed25519/RSA private-key authentication with device-only Keychain storage
- Unicode/CJK-aware terminal rendering and iOS composition input through SwiftTerm
- Unit and opt-in real-server integration tests for URL normalization, split behavior, workspaces, persistence, SSH, tmux, and live terminal resizing

## Build

```sh
ruby scripts/generate_project.rb
xcodebuild -project ModotBrowser.xcodeproj \
  -scheme ModotBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

The project targets iOS 26 to use App Intents' current `supportedModes` API. The UI is intentionally line-first, low-elevation, and shadcn-inspired.
