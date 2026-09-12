import AppKit
import SwiftUI

@MainActor
final class RecordingHUDController: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var audioLevel: Float = 0
    /// Shift+hotkey capture — HUD copy and color differ from dictation.
    @Published var isContextCapture = false
    /// Endonym of the take's language — English included, so the badge always
    /// says what the take is in rather than only speaking up when it differs.
    /// Nil when language support is off, which leaves the HUD as it was. The
    /// speaker learns the language before they have said anything, which is the
    /// whole reason it is on the HUD.
    @Published var languageBadge: String?
    /// Secondary status appended to the headline: the auto-stop countdown while
    /// recording, chunk progress while transcribing. A long take used to show a
    /// bare spinner for minutes with nothing to say how far along it was.
    @Published var detail: String?
    @Published var detailIsWarning = false
    /// Called when the user clicks the HUD's cancel button.
    var onCancel: (() -> Void)?
    /// Called when a microphone is chosen from the HUD. Nil means "follow System
    /// Settings" — the same thing the app did before there was a choice.
    var onSelectInput: ((String?) -> Void)?

    /// Microphones offered by the chip's menu, and the name the chip shows.
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var activeInputName: String?
    /// The pointer is on the HUD, so it stays up: that is the only way to reach
    /// the microphone menu after a take has finished.
    @Published private(set) var isHovering = false
    private var hidePending = false
    /// Menu items hold their target weakly, so the target has to outlive the call.
    private var menuTarget: HUDInputMenuTarget?

    /// A take can be abandoned while it is being recorded and while it is being
    /// worked on; an insert already in flight cannot be usefully stopped, so the
    /// button goes away for that one.
    ///
    /// Recording used to be missing here, which left Escape able to throw a take
    /// away and the HUD unable to — two affordances for one intent, one of them
    /// silently weaker.
    var isCancellable: Bool {
        switch phase {
        case .waitingForMic, .recording, .processing, .settingContext, .polishing: return true
        default: return false
        }
    }

    /// Re-read the connected microphones. Cheap enough to do whenever the HUD
    /// appears, and devices come and go while the app is running.
    func refreshInputs() {
        inputDevices = AudioInputSelection.inputDevices()
        activeInputName = AudioInputSelection.activeName(
            preferredUID: SettingsStore.shared.preferredInputDeviceUID,
            in: inputDevices
        )
    }

    /// The chip is worth showing while the mic is open or the take has just
    /// finished. It goes away for transcription and polish, where the microphone
    /// no longer has anything to do with this take.
    var showsInputChip: Bool {
        switch phase {
        case .waitingForMic, .recording, .success, .successNote: return activeInputName != nil
        default: return false
        }
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            // Keep it up: the pointer arriving is the request. `hidePending` is
            // left standing, so the HUD still knows it owes a hide — cancelling
            // the task used to be the whole story, and a pointer that arrived
            // before the timer fired left the HUD on screen for good.
            hideTask?.cancel()
        } else if hidePending {
            scheduleHide(after: 0.4)
        }
    }

    func selectInput(uid: String?) {
        onSelectInput?(uid)
        refreshInputs()
    }

    /// The microphone list, as a real NSMenu.
    ///
    /// A SwiftUI `Menu` wants a key window to track in, and this panel is never
    /// key — that is what keeps ⌘V landing in the app being dictated into. An
    /// NSMenu tracks on its own, so it opens over a panel that never takes focus.
    func showInputMenu() {
        guard let panel, let view = panel.contentView else { return }
        refreshInputs()
        let chosen = SettingsStore.shared.preferredInputDeviceUID
        let target = HUDInputMenuTarget { [weak self] uid in
            Task { @MainActor in self?.selectInput(uid: uid) }
        }
        menuTarget = target

        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        for (index, entry) in InputMenu.items(devices: inputDevices, chosenUID: chosen).enumerated() {
            if index == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: entry.title,
                action: entry.isEnabled ? #selector(HUDInputMenuTarget.pick(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = entry.isEnabled ? target : nil
            item.isEnabled = entry.isEnabled
            item.representedObject = entry.uid
            item.state = entry.isChecked ? .on : .off
            menu.addItem(item)
        }

        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: view.convert(inWindow, from: nil), in: view)
    }

    func setDetail(_ text: String?, warning: Bool = false) {
        detail = text
        detailIsWarning = warning && text != nil
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Where we last put the panel ourselves. `NSWindow.didMoveNotification` fires
    /// for our own `setFrameOrigin` exactly as it does for a drag, and carries
    /// nothing to tell them apart — so a move that landed where we aimed is ours,
    /// and anything else was the user's hand.
    private var lastProgrammaticOrigin: NSPoint?

    init() {
        // Position is otherwise only computed when the HUD is shown or updated, so
        // unplugging a display mid-take could leave it on a screen that no longer
        // exists.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel?.isVisible == true else { return }
                self.positionOnActiveScreen()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    func show(
        phase: DictationPhase,
        levelPublisher: AudioRecorder,
        contextCapture: Bool = false,
        language: SpokenLanguage? = nil
    ) {
        hideTask?.cancel()
        levelTimer?.invalidate()
        setDetail(nil)
        self.phase = phase
        self.isContextCapture = contextCapture
        self.languageBadge = language?.nativeName
        hidePending = false
        isHovering = false
        refreshInputs()
        ensurePanel()
        positionOnActiveScreen()
        // Mouse events are accepted the whole time the HUD is up, not just when
        // Cancel is there: hovering is what keeps it open long enough to change
        // the microphone. It only covers its own 330×76 at the bottom of the
        // screen, and only while a take is running or just finished.
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak levelPublisher] timer in
            guard let levelPublisher else {
                timer.invalidate()
                return
            }
            let level = levelPublisher.snapshotLevel()
            Task { @MainActor in
                guard let self, self.panel?.isVisible == true else {
                    timer.invalidate()
                    return
                }
                self.audioLevel = level
            }
        }
    }

    func update(phase: DictationPhase) {
        self.phase = phase
        ensurePanel()
        positionOnActiveScreen()
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
    }

    func setContextCapture(_ active: Bool) {
        isContextCapture = active
    }

    func flashSuccess(note: String? = nil) {
        setDetail(nil)
        refreshInputs()
        if let note, !note.isEmpty {
            phase = .successNote(note)
            scheduleHide(after: 1.6)
        } else {
            phase = .success
            scheduleHide(after: 0.8)
        }
    }

    func flashError(_ message: String) {
        isContextCapture = false
        setDetail(nil)
        phase = .error(message)
        scheduleHide(after: 2.0)
    }

    /// A keyboard switch while the key is held changed the take's language.
    func setLanguage(_ language: SpokenLanguage?) {
        languageBadge = language?.nativeName
    }

    func hide() {
        hideTask?.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        panel?.orderOut(nil)
        phase = .idle
        audioLevel = 0
        isContextCapture = false
        languageBadge = nil
        isHovering = false
        hidePending = false
    }

    /// Arms the hide. `hidePending` says the HUD is due to disappear and stays
    /// true until it does, so a hover can suspend the countdown at any point in it
    /// and the pointer leaving always re-arms.
    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hidePending = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Hovering means the pointer is on its way to the microphone menu.
            // Hold the HUD open; `setHovering(false)` schedules the real hide.
            guard !isHovering else { return }
            hide()
        }
    }

    /// The row of capsules hugs its content, so the panel follows it rather than
    /// the other way round. Called from the view whenever the layout changes.
    func fitPanel(to size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let wanted = NSSize(width: ceil(size.width), height: ceil(size.height))
        let current = panel.frame.size
        guard abs(current.width - wanted.width) > 0.5 || abs(current.height - wanted.height) > 0.5 else { return }
        panel.setContentSize(wanted)
        // Only ever grows. A phase wider than anything seen before moves the left
        // edge once, by half the growth, and then it is settled for good.
        if phaseSetsReservedWidth, wanted.width > reservedWidth {
            UserDefaults.standard.set(Double(wanted.width), forKey: Self.reservedWidthKey)
        }
        positionOnActiveScreen()
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hosting = HUDHostingView(rootView: RecordingHUDView(controller: self))
        hosting.sizingOptions = []
        // A starting size only: the view reports what it actually needs and the
        // panel is resized to fit.
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 64)
        hosting.autoresizingMask = [.width, .height]

        let panel = HUDPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Liquid Glass draws its own edge and depth. An AppKit window shadow on top
        // of translucent content is computed from that content's alpha, so instead
        // of a soft drop shadow it hugs the rounded rect as a thin dark rim.
        if #available(macOS 26.0, *) {
            panel.hasShadow = false
        } else {
            panel.hasShadow = true
        }
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pinned dark below macOS 26, where the panel is a hand-drawn dark material
        // and every colour in it was chosen for that. On 26 the appearance follows
        // the system so the glass sits at the brightness of whatever is behind it:
        // pinning dark tinted the capsule interiors darker than the background,
        // which is the one thing that stops glass reading as glass. The rim is
        // quieter in Light Mode as a result, and that is the right trade.
        if #unavailable(macOS 26.0) {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        // Dev only while the placement is being tried out. This is a gate for the
        // trial, not a decision — it has to be flipped on for Release once the
        // drag has been lived with, rather than left here shipping a difference
        // between the two builds that nobody chose.
        panel.isMovableByWindowBackground = Self.isRepositionable
        if Self.isRepositionable {
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rememberIfUserMoved() }
            }
        }
        self.panel = panel
        positionOnActiveScreen()
    }

    /// Dragging the HUD somewhere else, and remembering where.
    static var isRepositionable: Bool { AppIdentity.isDevBuild }

    private static let anchorXKey = "hudAnchorX"
    private static let anchorYKey = "hudAnchorY"

    /// Nil until the HUD has been dragged: absent keys and a stored 0 are not the
    /// same thing, and `double(forKey:)` cannot tell them apart on its own.
    private var customAnchor: CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.anchorXKey) != nil,
              defaults.object(forKey: Self.anchorYKey) != nil else { return nil }
        return CGPoint(
            x: defaults.double(forKey: Self.anchorXKey),
            y: defaults.double(forKey: Self.anchorYKey)
        )
    }

    /// Puts the HUD back where it ships, for anyone who has dragged it somewhere
    /// they regret.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorXKey)
        UserDefaults.standard.removeObject(forKey: Self.anchorYKey)
        positionOnActiveScreen()
    }

    private func rememberIfUserMoved() {
        guard Self.isRepositionable, let panel else { return }
        let origin = panel.frame.origin
        if let aimed = lastProgrammaticOrigin,
           abs(origin.x - aimed.x) < 0.5, abs(origin.y - aimed.y) < 0.5 { return }
        // The screen the panel is on, not the one the pointer is on: a drag can
        // finish with the pointer past the edge of the display it started from.
        guard let screen = panel.screen ?? Self.activeScreen(),
              let anchor = HUDPlacement.anchor(forOrigin: origin, in: screen.visibleFrame) else { return }
        UserDefaults.standard.set(Double(anchor.x), forKey: Self.anchorXKey)
        UserDefaults.standard.set(Double(anchor.y), forKey: Self.anchorYKey)
        lastProgrammaticOrigin = origin
    }

    /// The widest the row has ever needed, which is what the HUD reserves space
    /// for. The left edge is then a function of the screen alone, so the HUD opens
    /// in the same place on every take — the row grows to the right inside that
    /// reserved width instead of the panel re-centring around it.
    ///
    /// A remembered measurement, not a preference. The width depends on the phase,
    /// the language badge, the length of the microphone's name and the display's
    /// font, so a constant here would be wrong for somebody. This learns it once
    /// and then stops moving, across relaunches too.
    private static let reservedWidthKey = "hudReservedWidth"

    private var reservedWidth: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: Self.reservedWidthKey))
    }

    /// Learned from the phases a normal take passes through, and only those. An
    /// error or a note puts a whole sentence in the capsule — "Microphone isn't
    /// ready. Check System Settings…" — and letting one of those set the reserved
    /// width would leave every later take sitting far left of centre for good.
    private var phaseSetsReservedWidth: Bool {
        switch phase {
        case .error, .successNote: return false
        default: return true
        }
    }

    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func positionOnActiveScreen() {
        guard let panel, let screen = Self.activeScreen() else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin: CGPoint
        if Self.isRepositionable, let anchor = customAnchor {
            // The user put the left edge where they wanted it, so it is pinned
            // outright and the reserved width does not come into it.
            origin = HUDPlacement.origin(forAnchor: anchor, panelSize: size, in: frame)
        } else {
            // Centre the reserved width, not this phase's width. Narrower phases sit
            // a little left of centre; every phase and every take sits in one place,
            // which is the point.
            let reserved = max(reservedWidth, size.width)
            origin = HUDPlacement.clamp(
                CGPoint(x: frame.midX - reserved / 2, y: frame.minY + HUDPlacement.defaultBottomInset),
                panelSize: size,
                in: frame
            )
        }
        lastProgrammaticOrigin = origin
        panel.setFrameOrigin(origin)
    }
}

/// An indeterminate spinner we can actually colour.
///
/// `ProgressView` wraps `NSProgressIndicator`, which ignores `.tint` for the
/// spinning style, so on clear glass over a light document it faded to almost
/// nothing next to the white headline.
private struct HUDSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(HUDInk.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .shadow(color: HUDInk.shadow, radius: 1.5)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

/// One Liquid Glass capsule.
///
/// The HUD used to be a single 330×76 plate, and that is why it read as a frosted
/// slab: a large glass element is mostly interior, and interior is the one place
/// glass can only blur. What people recognise as Liquid Glass happens at the
/// edges — the lensing, the specular rim, and the content visible between
/// elements — so the HUD is now a row of capsules that each hug their content.
///
/// `.regular` rather than `.clear`: the clear variant has no adaptive behaviour
/// and, tested over a page of text, frosted *harder* than regular did in a
/// transparent panel. Regular keeps the content behind legible through the glass
/// and flips light or dark with the material.
private struct HUDPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.black.opacity(0.42)))
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// Capsules inside one container sample the same backdrop and can morph into one
/// another. Apple's own samples group their glass this way, and the documentation
/// is blunt about why: glass cannot sample other glass.
private struct HUDGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// Labels on Liquid Glass get a vibrant treatment and flip with the material, so
/// on macOS 26 they use the semantic colours and carry no shadow. Below that the
/// panel is a dark material by hand, where white plus a shadow is what reads.
enum HUDInk {
    static var primary: Color {
        if #available(macOS 26.0, *) { return .primary }
        return .white
    }

    static var secondary: Color {
        if #available(macOS 26.0, *) { return .secondary }
        return Color.white.opacity(0.75)
    }

    static var warning: Color {
        if #available(macOS 26.0, *) { return .orange }
        return .yellow
    }

    /// Clear on 26: a drop shadow under glass-vibrant text is what made it look
    /// smudged rather than crisp.
    static var shadow: Color {
        if #available(macOS 26.0, *) { return .clear }
        return .black.opacity(0.55)
    }
}

/// The HUD never becomes key, and a non-key window normally swallows the first click
/// just to focus itself. Without this the cancel button would need two clicks: one
/// discarded to focus a window that will never take focus, and one that lands.
private final class HUDHostingView: NSHostingView<RecordingHUDView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: RecordingHUDView) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Carries a menu click back to the controller. NSMenuItem dispatches through
/// the Objective-C runtime, so the target has to be an NSObject.
private final class HUDInputMenuTarget: NSObject {
    private let run: (String?) -> Void

    init(run: @escaping (String?) -> Void) {
        self.run = run
    }

    @objc func pick(_ sender: NSMenuItem) {
        run(sender.representedObject as? String)
    }
}

/// HUD must never become key — otherwise ⌘V lands in WhisperLocal instead of Cursor / Chrome.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Belt and braces for the drag. `isMovableByWindowBackground` only fires for a
    /// mouse-down the content view left alone, and an `NSHostingView` does not
    /// reliably leave one alone. Anything SwiftUI declines still travels up the
    /// responder chain to here, and `performDrag` runs the same drag loop AppKit
    /// would have. Whichever of the two gets the event, the HUD moves; the buttons
    /// keep their own clicks either way, because a click they handle never arrives.
    override func mouseDown(with event: NSEvent) {
        guard isMovableByWindowBackground else {
            super.mouseDown(with: event)
            return
        }
        performDrag(with: event)
    }
}

struct RecordingHUDView: View {
    @ObservedObject var controller: RecordingHUDController
    @ObservedObject private var settings = SettingsStore.shared
    @State private var cancelHovering = false
    @State private var micHovering = false

    /// The tallest a capsule gets on its own: 13pt semibold sets a 16pt line, and
    /// the padding adds 9 above and below. Levelling to the tallest means nothing
    /// has to shrink — the shorter capsules grow into it and the text keeps the
    /// room it had.
    private static let levelledPillHeight: CGFloat = 34

    /// Breathing room around the row, so a capsule's lensing and the merge between
    /// two of them are never clipped by the panel edge.
    private let margin: CGFloat = 10

    var body: some View {
        // Only where the HUD can actually be dragged: an empty context menu is a
        // right-click that does nothing, which is worse than no menu at all.
        if RecordingHUDController.isRepositionable {
            row.contextMenu {
                Button("Reset Position") { controller.resetPosition() }
            }
        } else {
            row
        }
    }

    private var row: some View {
        HUDGlassGroup {
            // 16pt apart, not 8: closer than that and the container tries to
            // bridge two capsules into one shape, which renders as a dark wedge
            // between them rather than the liquid merge it is going for.
            HStack(spacing: 16) {
                if let badge = controller.languageBadge {
                    pill { Text(badge).font(.system(size: 10, weight: .bold)) }
                }
                statusPill
                if controller.showsInputChip {
                    micPill
                }
                if controller.isCancellable {
                    cancelPill
                }
                if controller.isContextCapture {
                    pill { Text("CONTEXT").font(.system(size: 10, weight: .bold)) }
                } else if AppIdentity.isDevBuild {
                    pill { Text("DEV \(AppIdentity.versionSummary)").font(.system(size: 10, weight: .bold)) }
                }
            }
            .foregroundStyle(HUDInk.primary)
        }
        .padding(margin)
        // Take the row's own ideal width rather than whatever the panel currently
        // proposes. Without this the GeometryReader below reports the panel's size
        // back to the panel — a no-op — and the row is squeezed into it, which
        // clipped the leftmost capsule clean off: the language badge vanished.
        .fixedSize()
        // The row decides the size; the panel follows it.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in
                        controller.fitPanel(to: size)
                    }
            }
        }
        // Hovering holds the HUD open past its own timeout, which is the only way
        // to reach the microphone menu once a take has finished.
        .onHover { controller.setHovering($0) }
    }

    // MARK: - Capsules

    private var statusPill: some View {
        pill {
            HStack(spacing: 9) {
                statusIcon
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(controller.detailIsWarning ? HUDInk.warning : HUDInk.primary)
                    .shadow(color: HUDInk.shadow, radius: 2, y: 0.5)
                    .lineLimit(1)
                    .fixedSize()
                if controller.phase == .recording {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule()
                            .fill(controller.isContextCapture ? Color.orange : Color.accentColor)
                            .frame(width: max(4, 96 * CGFloat(min(1, controller.audioLevel))))
                    }
                    .frame(width: 96, height: 4)
                }
            }
        }
    }

    /// Names the microphone this take is on, and opens the list of the others.
    private var micPill: some View {
        Button {
            controller.showInputMenu()
        } label: {
            pill {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(controller.activeInputName ?? "Microphone")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 150, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .black))
                        .opacity(micHovering ? 0.9 : 0.6)
                }
                .foregroundStyle(HUDInk.primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { micHovering = $0 }
        .help("Choose the microphone")
        .accessibilityLabel("Microphone: \(controller.activeInputName ?? "system default"). Opens the list of microphones.")
    }

    private var cancelPill: some View {
        Button {
            controller.onCancel?()
        } label: {
            pill(horizontal: 10) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HUDInk.primary.opacity(cancelHovering ? 1 : 0.75))
            }
        }
        .buttonStyle(.plain)
        .onHover { cancelHovering = $0 }
        .help("Cancel this dictation")
        .accessibilityLabel("Cancel this dictation")
    }

    private func pill<Content: View>(
        horizontal: CGFloat = 13,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, horizontal)
            // Equal padding around unequal text gives unequal capsules: 10pt bold
            // lands at 30, 11pt medium at 31, 13pt semibold at 34. Centred in the
            // row, that splits into a couple of points of mismatch at the top and
            // the same again at the bottom — invisible on plain text, plain to see
            // on four glass rims sitting side by side.
            .padding(.vertical, 9)
            .frame(height: settings.levelHUDCapsules ? Self.levelledPillHeight : nil)
            .modifier(HUDPill())
    }

    private var headline: String {
        guard let detail = controller.detail, !detail.isEmpty else { return baseHeadline }
        return "\(baseHeadline) · \(detail)"
    }

    private var baseHeadline: String {
        if controller.isContextCapture {
            switch controller.phase {
            case .waitingForMic:
                return "Context: waiting for mic…"
            case .recording:
                return "Listening for context…"
            case .processing, .settingContext:
                return "Transcribing context…"
            case .polishing:
                return "Polishing context…"
            case .successNote(let note):
                return note
            default:
                return controller.phase.label
            }
        }
        return controller.phase.label
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.phase {
        case .waitingForMic:
            ProgressView()
                .controlSize(.small)
                .tint(HUDInk.primary)
        case .recording:
            Circle()
                .fill(controller.isContextCapture ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(
                    (controller.isContextCapture ? Color.orange : Color.red).opacity(0.4),
                    lineWidth: 6
                ))
        case .processing, .settingContext, .polishing, .inserting:
            HUDSpinner()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .successNote:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(HUDInk.warning)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HUDInk.warning)
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
    }
}
