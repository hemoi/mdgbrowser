import SwiftUI
import UIKit

struct BrowserPetOverlay: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let browserStore: WorkspaceBrowserStore
    let petStore: BrowserPetStore
    let aiStore: BrowserAIStore

    @GestureState private var dragTranslation = CGSize.zero
    @State private var dragAnimation: PetAnimationState?

    private let basePetSize = CGSize(width: 92, height: 100)

    var body: some View {
        @Bindable var petStore = petStore

        GeometryReader { geometry in
            let center = renderedCenter(in: geometry.size, translation: dragTranslation)
            let petSize = renderedPetSize
            let session = browserStore.session(for: browserStore.activePane)
            let animation = dragAnimation ?? (session.isLoading ? .running : petStore.animationState)

            ZStack {
                if petStore.quickActionsVisible {
                    PetQuickActionDock(
                        isLoading: session.isLoading,
                        reload: { toggleLoading(session) },
                        newTab: openNewTab,
                        openAI: openAI,
                        settings: openSettings
                    )
                    .position(actionDockCenter(for: center, petSize: petSize, canvasSize: geometry.size))
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
                    )
                    .zIndex(1)
                }

                PetSpriteView(animation: animation, reduceMotion: reduceMotion)
                    .frame(width: petSize.width, height: petSize.height)
                    .contentShape(Rectangle())
                    .position(center)
                    .onTapGesture {
                        withAnimation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.22)) {
                            petStore.toggleQuickActions()
                        }
                    }
                    .gesture(dragGesture(in: geometry.size))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Banana pet")
                    .accessibilityHint("Double tap to show browser shortcuts. Drag to move.")
                    .accessibilityIdentifier("pet.sample")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Reload active pane") {
                        toggleLoading(session)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $petStore.presentedSheet) { destination in
            switch destination {
            case .settings:
                PetSettingsSheet(store: petStore)
                    .environment(theme)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .allowsHitTesting(true)
    }

    private var renderedPetSize: CGSize {
        CGSize(
            width: basePetSize.width * petStore.scale,
            height: basePetSize.height * petStore.scale
        )
    }

    private func renderedCenter(in canvasSize: CGSize, translation: CGSize) -> CGPoint {
        let petSize = renderedPetSize
        let horizontalInset = petSize.width / 2 + 8
        let verticalInset = petSize.height / 2 + 8
        let usableWidth = max(canvasSize.width - horizontalInset * 2, 0)
        let usableHeight = max(canvasSize.height - verticalInset * 2, 0)
        let base = CGPoint(
            x: horizontalInset + usableWidth * petStore.position.x,
            y: verticalInset + usableHeight * petStore.position.y
        )

        return CGPoint(
            x: min(max(base.x + translation.width, horizontalInset), canvasSize.width - horizontalInset),
            y: min(max(base.y + translation.height, verticalInset), canvasSize.height - verticalInset)
        )
    }

    private func normalizedPosition(for center: CGPoint, in canvasSize: CGSize) -> PetPosition {
        let petSize = renderedPetSize
        let horizontalInset = petSize.width / 2 + 8
        let verticalInset = petSize.height / 2 + 8
        let usableWidth = max(canvasSize.width - horizontalInset * 2, 1)
        let usableHeight = max(canvasSize.height - verticalInset * 2, 1)

        return PetPosition(
            x: Double((center.x - horizontalInset) / usableWidth),
            y: Double((center.y - verticalInset) / usableHeight)
        ).clamped()
    }

    private func actionDockCenter(for petCenter: CGPoint, petSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let dockHalfWidth: CGFloat = 104
        let preferredY = petCenter.y - petSize.height / 2 - 28
        let y = preferredY >= 28 ? preferredY : petCenter.y + petSize.height / 2 + 28

        return CGPoint(
            x: min(max(petCenter.x, dockHalfWidth + 8), canvasSize.width - dockHalfWidth - 8),
            y: min(max(y, 28), canvasSize.height - 28)
        )
    }

    private func dragGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                if petStore.quickActionsVisible {
                    petStore.dismissQuickActions()
                }
                guard abs(value.translation.width) > 5 else { return }
                dragAnimation = value.translation.width > 0 ? .runningRight : .runningLeft
            }
            .onEnded { value in
                let center = renderedCenter(in: canvasSize, translation: value.translation)
                petStore.setPosition(normalizedPosition(for: center, in: canvasSize))
                dragAnimation = nil
            }
    }

    private func toggleLoading(_ session: BrowserSession) {
        if session.isLoading {
            session.stopLoading()
        } else {
            session.reload()
        }
        petStore.dismissQuickActions()
    }

    private func openNewTab() {
        browserStore.addTab()
        petStore.dismissQuickActions()
        petStore.playWave()
    }

    private func openAI() {
        aiStore.present()
        petStore.dismissQuickActions()
        petStore.playWave()
    }

    private func openSettings() {
        petStore.dismissQuickActions()
        petStore.presentedSheet = .settings
    }
}

private struct PetQuickActionDock: View {
    @Environment(BrowserTheme.self) private var theme

    let isLoading: Bool
    let reload: () -> Void
    let newTab: () -> Void
    let openAI: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                systemName: isLoading ? "xmark" : "arrow.clockwise",
                label: isLoading ? "Stop loading" : "Reload",
                identifier: "pet.action.reload",
                action: reload
            )
            actionButton(
                systemName: "plus",
                label: "New tab",
                identifier: "pet.action.new-tab",
                action: newTab
            )
            actionButton(
                systemName: "sparkles",
                label: "Open AI assistant",
                identifier: "pet.action.ai",
                action: openAI
            )
            actionButton(
                systemName: "slider.horizontal.3",
                label: "Pet settings",
                identifier: "pet.action.settings",
                action: settings
            )
        }
        .padding(4)
        .background(theme.raisedBackground, in: Capsule())
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: 0.75)
        }
        .shadow(color: theme.label.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        systemName: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct PetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: BrowserPetStore

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section("Sample Pet") {
                    LabeledContent("Pet", value: "Banana")

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text(store.scale, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { store.scale },
                                set: { store.setScale($0) }
                            ),
                            in: BrowserPetStore.scaleRange,
                            step: 0.05
                        )
                        .accessibilityLabel("Pet size")
                    }
                }

                Section {
                    Button("Reset Position", systemImage: "arrow.counterclockwise") {
                        store.resetPosition()
                    }
                }
            }
            .navigationTitle("Pet Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PetSpriteView: View {
    let animation: PetAnimationState
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            PetAtlasFrameView(row: animation.row, column: 0)
                .transaction { transaction in
                    transaction.animation = nil
                }
        } else {
            TimelineView(.periodic(from: .now, by: animation.frameDuration)) { context in
                let frame = Int(context.date.timeIntervalSinceReferenceDate / animation.frameDuration)
                    % animation.frameCount
                PetAtlasFrameView(row: animation.row, column: frame)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
    }
}

private struct PetAtlasFrameView: UIViewRepresentable {
    let row: Int
    let column: Int

    func makeUIView(context: Context) -> PetAtlasView {
        PetAtlasView()
    }

    func updateUIView(_ view: PetAtlasView, context: Context) {
        view.show(row: row, column: column)
    }
}

private final class PetAtlasView: UIView {
    private static let columns: CGFloat = 8
    private static let rows: CGFloat = 9
    private static let atlasImage: CGImage? = {
        guard let url = Bundle.main.url(
            forResource: "spritesheet",
            withExtension: "webp",
            subdirectory: "Pets/banana"
        ) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)?.cgImage
    }()

    private let spriteLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        spriteLayer.contents = Self.atlasImage
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .linear
        spriteLayer.minificationFilter = .linear
        spriteLayer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "contentsRect": NSNull(),
            "position": NSNull(),
        ]
        layer.addSublayer(spriteLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard spriteLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = bounds
        CATransaction.commit()
    }

    func show(row: Int, column: Int) {
        let safeRow = min(max(row, 0), Int(Self.rows) - 1)
        let safeColumn = min(max(column, 0), Int(Self.columns) - 1)
        let contentsRect = CGRect(
            x: CGFloat(safeColumn) / Self.columns,
            y: CGFloat(safeRow) / Self.rows,
            width: 1 / Self.columns,
            height: 1 / Self.rows
        )
        guard spriteLayer.contentsRect != contentsRect else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contentsRect = contentsRect
        CATransaction.commit()
    }
}

#Preview("Sample Pet") {
    BrowserPetOverlay(
        browserStore: WorkspaceBrowserStore(),
        petStore: BrowserPetStore(),
        aiStore: BrowserAIStore()
    )
    .environment(BrowserTheme())
    .frame(width: 390, height: 680)
    .background(Color(uiColor: .systemBackground))
}
