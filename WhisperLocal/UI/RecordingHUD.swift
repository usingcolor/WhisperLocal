import AppKit
import SwiftUI

@MainActor
final class RecordingHUDController: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var audioLevel: Float = 0
    /// Shift+hotkey capture — HUD copy and color differ from dictation.
    @Published var isContextCapture = false

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var levelTimer: Timer?

    func show(phase: DictationPhase, levelPublisher: AudioRecorder, contextCapture: Bool = false) {
        hideTask?.cancel()
        levelTimer?.invalidate()
        self.phase = phase
        self.isContextCapture = contextCapture
        ensurePanel()
        positionOnActiveScreen()
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
        panel?.orderFrontRegardless()
    }

    func setContextCapture(_ active: Bool) {
        isContextCapture = active
    }

    func flashSuccess(note: String? = nil) {
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

        let hosting = NSHostingView(rootView: RecordingHUDView(controller: self))
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
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

/// HUD must never become key — otherwise ⌘V lands in WhisperLocal instead of Cursor / Chrome.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct RecordingHUDView: View {
    @ObservedObject var controller: RecordingHUDController

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300, height: 72)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
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
            ProgressView()
                .controlSize(.small)
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
