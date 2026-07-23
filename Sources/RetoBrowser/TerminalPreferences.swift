import Foundation
import SwiftTerm
import UIKit

enum TerminalFontChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case d2Coding
    case systemMonospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d2Coding: "D2Coding"
        case .systemMonospaced: "SF Mono"
        }
    }

    func font(size: CGFloat) -> UIFont {
        switch self {
        case .d2Coding:
            UIFont(name: "D2Coding", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .systemMonospaced:
            UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

enum TerminalThemePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case midnight
    case graphite
    case paper
    case solarizedDark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .paper: "Paper"
        case .solarizedDark: "Solarized"
        }
    }

    var backgroundHex: UInt32 {
        switch self {
        case .midnight: 0x090B0E
        case .graphite: 0x1C1C1E
        case .paper: 0xF7F7F4
        case .solarizedDark: 0x002B36
        }
    }

    var foregroundHex: UInt32 {
        switch self {
        case .midnight: 0xE6EDF3
        case .graphite: 0xF2F2F7
        case .paper: 0x202124
        case .solarizedDark: 0x93A1A1
        }
    }

    var cursorHex: UInt32 {
        switch self {
        case .midnight: 0x5AC8FA
        case .graphite: 0xFFD60A
        case .paper: 0x007AFF
        case .solarizedDark: 0x2AA198
        }
    }

    var previewHexes: [UInt32] {
        Array(paletteHexes.prefix(4))
    }

    var paletteHexes: [UInt32] {
        switch self {
        case .midnight:
            [0x0D1117, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
             0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC]
        case .graphite:
            [0x1C1C1E, 0xFF453A, 0x30D158, 0xFFD60A, 0x0A84FF, 0xBF5AF2, 0x64D2FF, 0xD1D1D6,
             0x636366, 0xFF6961, 0x32D74B, 0xFFD426, 0x409CFF, 0xDA8FFF, 0x70D7FF, 0xFFFFFF]
        case .paper:
            [0x202124, 0xC5221F, 0x188038, 0xB06000, 0x185ABC, 0xA142F4, 0x007B83, 0xDADCE0,
             0x5F6368, 0xD93025, 0x1E8E3E, 0xE37400, 0x1967D2, 0xA50E0E, 0x00838F, 0xFFFFFF]
        case .solarizedDark:
            [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
             0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
        }
    }

    var backgroundColor: UIColor { UIColor(terminalHex: backgroundHex) }
    var foregroundColor: UIColor { UIColor(terminalHex: foregroundHex) }
    var cursorColor: UIColor { UIColor(terminalHex: cursorHex) }

    var swiftTermPalette: [SwiftTerm.Color] {
        paletteHexes.map { value in
            SwiftTerm.Color(
                red: UInt16((value >> 16) & 0xFF) * 257,
                green: UInt16((value >> 8) & 0xFF) * 257,
                blue: UInt16(value & 0xFF) * 257
            )
        }
    }
}

enum TerminalHotkey: String, Codable, CaseIterable, Identifiable, Sendable {
    case escape, tab, shiftTab, controlC, controlD, controlL, controlZ
    case paste, slash, pipe, tilde, dash, colon, period
    case arrowLeft, arrowUp, arrowDown, arrowRight
    case returnKey

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .controlC: "⌃C"
        case .controlD: "⌃D"
        case .controlL: "⌃L"
        case .controlZ: "⌃Z"
        case .paste: "paste"
        case .slash: "/"
        case .pipe: "|"
        case .tilde: "~"
        case .dash: "−"
        case .colon: ":"
        case .period: "."
        case .arrowLeft: "◀"
        case .arrowUp: "▲"
        case .arrowDown: "▼"
        case .arrowRight: "▶"
        case .returnKey: "↵"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .controlC: "Control C"
        case .controlD: "Control D"
        case .controlL: "Control L"
        case .controlZ: "Control Z"
        case .paste: "Paste"
        case .slash: "Slash"
        case .pipe: "Pipe"
        case .tilde: "Tilde"
        case .dash: "Dash"
        case .colon: "Colon"
        case .period: "Period"
        case .arrowLeft: "Left Arrow"
        case .arrowUp: "Up Arrow"
        case .arrowDown: "Down Arrow"
        case .arrowRight: "Right Arrow"
        case .returnKey: "Return"
        }
    }

    var bytes: [UInt8]? {
        switch self {
        case .escape: [0x1B]
        case .tab: [0x09]
        case .shiftTab: [0x1B, 0x5B, 0x5A]
        case .controlC: [0x03]
        case .controlD: [0x04]
        case .controlL: [0x0C]
        case .controlZ: [0x1A]
        case .slash: [0x2F]
        case .pipe: [0x7C]
        case .tilde: [0x7E]
        case .dash: [0x2D]
        case .colon: [0x3A]
        case .period: [0x2E]
        case .arrowLeft: [0x1B, 0x5B, 0x44]
        case .arrowUp: [0x1B, 0x5B, 0x41]
        case .arrowDown: [0x1B, 0x5B, 0x42]
        case .arrowRight: [0x1B, 0x5B, 0x43]
        case .returnKey: [0x0D]
        case .paste: nil
        }
    }
}

struct TerminalHotkeyGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var keys: [TerminalHotkey]

    init(id: UUID = UUID(), keys: [TerminalHotkey]) {
        self.id = id
        self.keys = Self.normalized(keys)
    }

    private static func normalized(_ keys: [TerminalHotkey]) -> [TerminalHotkey] {
        let fallback: [TerminalHotkey] = [.escape, .tab, .controlC, .returnKey]
        return Array((keys + fallback).prefix(4))
    }

    static let command = TerminalHotkeyGroup(
        id: UUID(uuidString: "67C32258-30CB-4C62-AE36-1021B2722A01")!,
        keys: [.tab, .controlC, .escape, .shiftTab]
    )
    static let punctuation = TerminalHotkeyGroup(
        id: UUID(uuidString: "67C32258-30CB-4C62-AE36-1021B2722A02")!,
        keys: [.paste, .slash, .colon, .period]
    )
    static let arrows = TerminalHotkeyGroup(
        id: UUID(uuidString: "67C32258-30CB-4C62-AE36-1021B2722A03")!,
        keys: [.arrowLeft, .arrowUp, .arrowDown, .arrowRight]
    )
    static let shell = TerminalHotkeyGroup(keys: [.slash, .pipe, .tilde, .dash])
    static let controls = TerminalHotkeyGroup(keys: [.escape, .controlD, .controlL, .controlZ])
}

struct TerminalPreferences: Codable, Equatable, Sendable {
    static let storageKey = "reto-browser.terminal-preferences.v1"
    static let defaultFontSize = 14.0

    var font: TerminalFontChoice
    var fontSize: Double
    var theme: TerminalThemePreset
    var hotkeyGroups: [TerminalHotkeyGroup]

    init(
        font: TerminalFontChoice = .d2Coding,
        fontSize: Double = Self.defaultFontSize,
        theme: TerminalThemePreset = .midnight,
        hotkeyGroups: [TerminalHotkeyGroup] = [.command, .punctuation, .arrows]
    ) {
        self.font = font
        self.fontSize = min(max(fontSize, 10), 28)
        self.theme = theme
        self.hotkeyGroups = hotkeyGroups.isEmpty ? [.command] : hotkeyGroups
    }

    static func load(from defaults: UserDefaults) -> TerminalPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TerminalPreferences.self, from: data)
        else { return TerminalPreferences() }
        return TerminalPreferences(
            font: decoded.font,
            fontSize: decoded.fontSize,
            theme: decoded.theme,
            hotkeyGroups: decoded.hotkeyGroups
        )
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

final class RetoTerminalAccessoryView: UIInputView {
    private weak var terminalView: RetoTerminalView?
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    init(terminalView: RetoTerminalView, groups: [TerminalHotkeyGroup]) {
        self.terminalView = terminalView
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setupLayout()
        configure(groups: groups)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(groups: [TerminalHotkeyGroup]) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, group) in groups.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.widthAnchor.constraint(
                    equalToConstant: 1 / max(traitCollection.displayScale, 1)
                ).isActive = true
                stackView.addArrangedSubview(separator)
            }

            for key in group.keys.prefix(4) {
                stackView.addArrangedSubview(makeButton(for: key))
            }
        }
    }

    private func setupLayout() {
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -8)
        ])
    }

    private func makeButton(for key: TerminalHotkey) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = key.shortLabel
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)

        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.send(key)
        })
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.accessibilityLabel = key.accessibilityLabel
        button.accessibilityIdentifier = "terminal.hotkey.\(key.rawValue)"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return button
    }

    private func send(_ key: TerminalHotkey) {
        if key == .paste {
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            terminalView?.send(txt: text)
        } else if let bytes = key.bytes {
            terminalView?.send(bytes)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }
}

extension UIColor {
    convenience init(terminalHex value: UInt32) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
