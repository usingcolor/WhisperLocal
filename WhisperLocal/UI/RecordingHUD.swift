import AppKit
import SwiftUI

@MainActor
final class RecordingHUDController: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var audioLevel: Float = 0
    /// Shift+hotkey capture — HUD copy and color differ from dictation.
    @Published var isContextCapture = false
    /// Secondary status appended to the headline: the auto-stop countdown while
    /// recording, chunk progress while transcribing. A long take used to show a
    /// bare spinner for minutes with nothing to say how far along it was.
    @Published var detail: String?
    @Published var detailIsWarning = false
    /// Called when the user clicks the HUD's cancel button.
    var onCancel: (() -> Void)?

    /// Transcription and polish can be abandoned; an insert already in flight cannot
    /// be usefully stopped, so the button goes away for it.
    var isCancellable: Bool {
        switch phase {
        case .processing, .settingContext, .polishing: return true
        default: return false
        }
    }

    func setDetail(_ text: String?, warning: Bool = false) {
        detail = text
        detailIsWarning = warning && text != nil
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var screenObserver: NSObjectProtocol?

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
    }

    func show(phase: DictationPhase, levelPublisher: AudioRecorder, contextCapture: Bool = false) {
        hideTask?.cancel()
        levelTimer?.invalidate()
        setDetail(nil)
        self.phase = phase
        self.isContextCapture = contextCapture
        ensurePanel()
        positionOnActiveScreen()
        panel?.ignoresMouseEvents = !isCancellable
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
        panel?.ignoresMouseEvents = !isCancellable
        panel?.orderFrontRegardless()
    }

    func setContextCapture(_ active: Bool) {
        isContextCapture = active
    }

    func flashSuccess(note: String? = nil) {
        setDetail(nil)
        panel?.ignoresMouseEvents = true
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
        panel?.ignoresMouseEvents = true
        phase = .error(message)
        scheduleHide(after: 2.0)
    }

    func hide() {
        hideTask?.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        panel?.orderOut(nil)
        phase = .idle
        audioLevel = 0
        isContextCapture = false
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hosting = HUDHostingView(rootView: RecordingHUDView(controller: self))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 72)

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
        // Every colour in this view — headline, level meter, border, the cancel
        // button's disc — is chosen for a dark material. In Light Mode
        // .ultraThinMaterial resolves light and all of it washes out, the headline
        // worst of all. Pinning the appearance keeps the design coherent instead of
        // half-adapting seven colours to a look this HUD was never drawn for.
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel
        positionOnActiveScreen()
    }

    private func positionOnActiveScreen() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

/// Liquid Glass where the OS has it, the older material treatment below.
///
/// The manual version needs a dark scrim: a material alone lightens toward whatever
/// is behind it, so over a white document the HUD drifted to mid-grey and took the
/// white text with it. Real glass handles that itself, and brings its own edge
/// highlight, so the hand-drawn border goes with the scrim on macOS 26.
private struct HUDSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.42)))
                }
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
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

/// HUD must never become key — otherwise ⌘V lands in WhisperLocal instead of Cursor / Chrome.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct RecordingHUDView: View {
    @ObservedObject var controller: RecordingHUDController
    @State private var cancelHovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(controller.detailIsWarning ? Color.yellow : .white)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                    .lineLimit(2)
                if controller.phase == .recording {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(controller.isContextCapture ? Color.orange : Color.accentColor)
                            .frame(width: max(4, 168 * CGFloat(min(1, controller.audioLevel))))
                    }
                    .frame(width: 168, height: 4)
                }
            }
            Spacer(minLength: 0)
            if controller.isCancellable {
                Button {
                    controller.onCancel?()
                } label: {
                    // Two-tone: a solid disc carries the contrast and the glyph is
                    // punched out of it, so it stays legible whatever the material
                    // picks up from behind the panel. A single translucent white
                    // glyph vanished against a light background.
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            Color.black.opacity(0.7),
                            Color.white.opacity(cancelHovering ? 1 : 0.85)
                        )
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .onHover { cancelHovering = $0 }
                .help("Cancel this dictation")
                .accessibilityLabel("Cancel this dictation")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300, height: 72)
        .modifier(HUDSurface())
        .overlay(alignment: .topTrailing) {
            if controller.isContextCapture {
                Text("CONTEXT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.95), in: Capsule())
                    .padding(8)
            } else if AppIdentity.isDevBuild {
                Text("DEV \(AppIdentity.versionSummary)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.95), in: Capsule())
                    .padding(8)
            }
        }
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
                .tint(.white)
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
                .foregroundStyle(.yellow)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
    }
}
