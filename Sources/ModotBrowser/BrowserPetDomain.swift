import Foundation
import Observation

enum PetAnimationState: String, CaseIterable {
    case idle
    case runningRight
    case runningLeft
    case waving
    case running

    var row: Int {
        switch self {
        case .idle:
            0
        case .runningRight:
            1
        case .runningLeft:
            2
        case .waving:
            3
        case .running:
            7
        }
    }

    var frameCount: Int {
        switch self {
        case .idle, .running:
            6
        case .runningRight, .runningLeft:
            8
        case .waving:
            4
        }
    }

    var frameDuration: TimeInterval {
        switch self {
        case .idle:
            0.88
        case .runningRight, .runningLeft:
            0.13
        case .waving:
            0.18
        case .running:
            0.16
        }
    }
}

struct PetPosition: Codable, Equatable {
    var x: Double
    var y: Double

    static let defaultPosition = PetPosition(x: 0.06, y: 0.9)

    func clamped() -> PetPosition {
        PetPosition(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

struct BrowserPetSnapshot: Codable, Equatable {
    var scale: Double
    var position: PetPosition
}

enum BrowserPetSheetDestination: String, Identifiable {
    case settings

    var id: String { rawValue }
}

@MainActor
@Observable
final class BrowserPetStore {
    static let defaultStorageKey = "modot-browser.pet.v1"
    static let scaleRange = 0.6...1.5

    var scale: Double
    var position: PetPosition
    var quickActionsVisible = false
    var animationState: PetAnimationState = .idle
    var presentedSheet: BrowserPetSheetDestination?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var animationResetTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = BrowserPetStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(BrowserPetSnapshot.self, from: data) {
            scale = Self.clampedScale(snapshot.scale)
            position = snapshot.position.clamped()
        } else {
            scale = 1
            position = .defaultPosition
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-show-sample-pet-actions") {
            quickActionsVisible = true
        }
        #endif
    }

    func toggleQuickActions() {
        quickActionsVisible.toggle()
        if quickActionsVisible {
            playWave()
        }
    }

    func dismissQuickActions() {
        quickActionsVisible = false
    }

    func setScale(_ value: Double) {
        scale = Self.clampedScale(value)
        persist()
    }

    func setPosition(_ value: PetPosition) {
        position = value.clamped()
        persist()
    }

    func resetPosition() {
        position = .defaultPosition
        persist()
    }

    func playWave() {
        animationResetTask?.cancel()
        animationState = .waving
        animationResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(760))
            guard !Task.isCancelled else { return }
            self?.animationState = .idle
        }
    }

    private static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    private func persist() {
        let snapshot = BrowserPetSnapshot(scale: scale, position: position)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
