import SwiftUI
import UIKit

struct BrowserPetOverlay: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let browserStore: WorkspaceBrowserStore
    let petStore: BrowserPetStore
    let aiStore: BrowserAIStore
    let terminalStore: TerminalWorkspaceStore

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
                if let message = petStore.activeMessage {
                    PetSpeechBubble(text: message.text) {
                        if let tabID = message.sourceTerminalTabID {
                            terminalStore.presentTerminal()
                            terminalStore.selectTab(tabID)
                        }
                        petStore.dismissActiveMessage()
                    }
                    .position(messageBubbleCenter(for: center, petSize: petSize, canvasSize: geometry.size))
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity)
                    )
                    .zIndex(2)
                }

                if petStore.quickActionsVisible {
                    PetQuickActionDock(
                        actions: petStore.quickActions,
                        isLoading: session.isLoading,
                        autoScrollEnabled: session.autoScrollEnabled,
                        perform: perform,
                        toggleAutoScroll: session.toggleAutoScroll,
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

                PetSpriteView(atlas: petStore.activeAtlas, animation: animation, reduceMotion: reduceMotion)
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
                    .accessibilityLabel("Browser pet")
                    .accessibilityHint("Double tap to show browser shortcuts. Drag to move.")
                    .accessibilityIdentifier("pet.sample")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Reload active pane") {
                        toggleLoading(session)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.22),
                value: petStore.activeMessage
            )
        }
        .sheet(item: $petStore.presentedSheet) { destination in
            switch destination {
            case .settings:
                PetSettingsSheet(store: petStore, session: browserStore.session(for: browserStore.activePane))
                    .environment(theme)
                    .presentationDetents([.large])
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

    private func messageBubbleCenter(for petCenter: CGPoint, petSize: CGSize, canvasSize: CGSize) -> CGPoint {
        // Sits above the pet, and above the quick-action dock when it is open.
        let dockClearance: CGFloat = petStore.quickActionsVisible ? 52 : 0
        let preferredY = petCenter.y - petSize.height / 2 - 32 - dockClearance
        let y = preferredY >= 26 ? preferredY : petCenter.y + petSize.height / 2 + 32 + dockClearance

        return CGPoint(
            x: min(max(petCenter.x, 118), max(canvasSize.width - 118, 118)),
            y: min(max(y, 26), canvasSize.height - 26)
        )
    }

    private func actionDockCenter(for petCenter: CGPoint, petSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let dockHalfWidth = CGFloat(petStore.quickActions.count + 2) * 24 + 12
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

    private func perform(_ action: PetQuickAction) {
        let session = browserStore.session(for: browserStore.activePane)
        switch action {
        case .reload:
            toggleLoading(session)
            return
        case .newTab:
            browserStore.addTab()
        case .goBack:
            session.goBack()
        case .goForward:
            session.goForward()
        case .openAI:
            aiStore.present()
        case .toggleTerminal:
            terminalStore.toggleSurface()
        case .toggleSplit:
            browserStore.toggleSplit()
        case .commandPalette:
            browserStore.commandPalettePresented = true
        case .copyPageURL:
            if let url = browserStore.currentPageURL {
                UIPasteboard.general.string = url.absoluteString
                browserStore.toastMessage = "Page link copied"
            } else {
                browserStore.toastMessage = "Open a webpage first"
            }
        case .pasteAndGo:
            if let raw = UIPasteboard.general.string,
               let url = BrowserURL.resolve(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                browserStore.open(url)
            } else {
                browserStore.toastMessage = "Clipboard has no address"
            }
        case .sendKey(let keystroke):
            if !terminalStore.sendKeystroke(keystroke) {
                browserStore.toastMessage = "Connect an SSH terminal first"
            }
        }
        petStore.dismissQuickActions()
        petStore.playWave()
    }

    private func toggleLoading(_ session: BrowserSession) {
        if session.isLoading {
            session.stopLoading()
        } else {
            session.reload()
        }
        petStore.dismissQuickActions()
    }

    private func openSettings() {
        petStore.dismissQuickActions()
        petStore.presentedSheet = .settings
    }
}

private struct PetSpeechBubble: View {
    @Environment(BrowserTheme.self) private var theme

    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.label)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: 220, alignment: .leading)
                .background(theme.raisedBackground, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(theme.border, lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pet message: \(text)")
        .accessibilityHint("Double tap to open the terminal tab it came from.")
        .accessibilityIdentifier("pet.message")
    }
}

private struct PetQuickActionDock: View {
    @Environment(BrowserTheme.self) private var theme

    let actions: [PetQuickAction]
    let isLoading: Bool
    let autoScrollEnabled: Bool
    let perform: (PetQuickAction) -> Void
    let toggleAutoScroll: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                actionButton(
                    systemName: action == .reload && isLoading ? "xmark" : action.systemImage,
                    label: action == .reload && isLoading ? "Stop loading" : action.label,
                    identifier: "pet.action.\(action.id)"
                ) {
                    perform(action)
                }
            }

            actionButton(
                systemName: autoScrollEnabled ? "pause.fill" : "arrow.down",
                label: autoScrollEnabled ? "Pause auto-scroll" : "Start auto-scroll",
                identifier: "pet.action.auto-scroll",
                isActive: autoScrollEnabled,
                action: toggleAutoScroll
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
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        systemName: String,
        label: String,
        identifier: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? theme.tailnet : theme.label)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct PetSettingsSheet: View {
    @Environment(BrowserTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var galleryPresented = false

    let store: BrowserPetStore
    let session: BrowserSession

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section("Pet") {
                    petRow(name: "Banana (bundled)", petID: nil)
                    ForEach(store.installedPets) { pet in
                        petRow(name: pet.displayName, petID: pet.id)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.deletePet(pet.id)
                                }
                            }
                    }

                    Button("Get pets from codex-pets.net", systemImage: "sparkle.magnifyingglass") {
                        galleryPresented = true
                    }
                    .accessibilityIdentifier("pet.settings.gallery")
                }

                Section {
                    ForEach(0..<PetQuickAction.maxSlots, id: \.self) { index in
                        Picker("Button \(index + 1)", selection: slotBinding(index)) {
                            Text("None").tag(PetQuickAction?.none)
                            ForEach(PetQuickAction.allOptions) { option in
                                Label(option.label, systemImage: option.systemImage)
                                    .tag(Optional(option))
                            }
                        }
                    }
                } header: {
                    Text("Quick actions")
                } footer: {
                    Text("Key actions send Esc, Ctrl+C, arrows, and friends straight to the focused SSH terminal.")
                }

                Section("Reading") {
                    Toggle(
                        "Auto-scroll",
                        isOn: Binding(
                            get: { session.autoScrollEnabled },
                            set: { session.setAutoScrollEnabled($0) }
                        )
                    )
                    .accessibilityIdentifier("pet.settings.auto-scroll")
                }

                Section("Appearance") {
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
        .sheet(isPresented: $galleryPresented) {
            CodexPetGallerySheet(petStore: store)
                .environment(theme)
                .presentationDetents([.large])
        }
    }

    private func petRow(name: String, petID: String?) -> some View {
        Button {
            store.applyPet(petID)
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if store.selectedPetID == petID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<PetQuickAction?> {
        Binding(
            get: { store.quickAction(at: index) },
            set: { store.setQuickAction($0, at: index) }
        )
    }
}

private struct PetSpriteView: View {
    let atlas: ActivePetAtlas
    let animation: PetAnimationState
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            PetAtlasFrameView(atlas: atlas, row: animation.row, column: 0)
                .transaction { transaction in
                    transaction.animation = nil
                }
        } else {
            TimelineView(.periodic(from: .now, by: animation.frameDuration)) { context in
                let frame = Int(context.date.timeIntervalSinceReferenceDate / animation.frameDuration)
                    % animation.frameCount
                PetAtlasFrameView(atlas: atlas, row: animation.row, column: frame)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
    }
}

private struct PetAtlasFrameView: UIViewRepresentable {
    let atlas: ActivePetAtlas
    let row: Int
    let column: Int

    func makeUIView(context: Context) -> PetAtlasView {
        PetAtlasView()
    }

    func updateUIView(_ view: PetAtlasView, context: Context) {
        view.show(atlas: atlas, row: row, column: column)
    }
}

private final class PetAtlasView: UIView {
    private let spriteLayer = CALayer()
    private var atlasKey: String?
    private var columns = 8
    private var rows = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
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

    func show(atlas: ActivePetAtlas, row: Int, column: Int) {
        if atlasKey != atlas.key {
            atlasKey = atlas.key
            columns = max(atlas.columns, 1)
            rows = max(atlas.rows, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spriteLayer.contents = atlas.image
            CATransaction.commit()
        }

        let safeRow = min(max(row, 0), rows - 1)
        let safeColumn = min(max(column, 0), columns - 1)
        let contentsRect = CGRect(
            x: CGFloat(safeColumn) / CGFloat(columns),
            y: CGFloat(safeRow) / CGFloat(rows),
            width: 1 / CGFloat(columns),
            height: 1 / CGFloat(rows)
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
        aiStore: BrowserAIStore(),
        terminalStore: TerminalWorkspaceStore()
    )
    .environment(BrowserTheme())
    .frame(width: 390, height: 680)
    .background(Color(uiColor: .systemBackground))
}
