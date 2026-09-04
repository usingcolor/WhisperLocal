import SwiftUI

struct SessionContextEditor: View {
    @ObservedObject var controller: DictationController
    var showsIntro: Bool = false
    /// Only the standalone window closes on save. Embedded in Settings this would
    /// close the Settings window, which is not what saving a phrase should do.
    var closesAfterSave: Bool = false

    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    /// Drives the relative age label. Without it "set 2 min ago" is frozen at
    /// whatever it said when the window opened.
    @State private var now = Date()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsIntro {
                Text("Session Context")
                    .font(.headline)
                Text("Sent with later dictations so names and jargon resolve. Nothing is pasted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusRow

            // Empty label + `prompt:`, matching the other multi-line fields on this
            // page. Passing the string as the label instead puts it beside the box
            // inside a Form — where it is not grey and never goes away as you type.
            TextField("", text: $draft, prompt: Text(Self.placeholder), axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )

            footer
        }
        .onAppear { draft = controller.sessionContextText }
        .onReceive(tick) { now = $0 }
        .onChange(of: controller.sessionContext) { _, _ in
            draft = controller.sessionContextText
            now = Date()
        }
        .onChange(of: draft) { _, newValue in
            if newValue.count > SessionContext.maxCharacters {
                let end = newValue.index(newValue.startIndex, offsetBy: SessionContext.maxCharacters)
                draft = String(newValue[..<end])
            }
        }
    }

    /// The model already tracks when the phrase was set and how close it is to
    /// expiring; none of that used to reach the screen, so the window could not
    /// answer "is this even active right now?".
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.hasActiveSessionContext ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(statusTitle)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text(expiryHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if showsCount {
                Text("\(draft.count)/\(SessionContext.maxCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(draft.count >= SessionContext.maxCharacters ? Color.orange : .secondary)
            }
            if let note {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Clear", role: .destructive) { clear() }
                .disabled(!canClear)
            Button("Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
    }

    private var statusTitle: String {
        guard settings.enableSessionContext else { return "Session context is off" }
        guard controller.hasActiveSessionContext,
              let context = controller.sessionContext else {
            return "No context set"
        }
        if let age = SessionContext.ageLabel(setAt: context.setAt, now: now) {
            return "Active · set \(age)"
        }
        return "Active · just set"
    }

    /// Spell the expiry rules out. They are invisible otherwise, and a phrase that
    /// vanishes on its own is alarming if you did not know it could.
    private var expiryHint: String {
        guard settings.enableSessionContext else { return "Enable it in Settings" }
        guard controller.hasActiveSessionContext, let context = controller.sessionContext else {
            return "Hold Shift while dictating to set one"
        }
        let remaining = SessionContext.strikesToClear - context.driftStrikes
        let idleMinutes = Int(SessionContext.idleExpiry / 60)
        if context.driftStrikes > 0 {
            return "\(remaining) unrelated take\(remaining == 1 ? "" : "s") from clearing"
        }
        return "Clears after \(idleMinutes) min idle"
    }

    /// An example reads better than an instruction, and shows what the feature is
    /// actually for: a topic plus the names and jargon that should resolve.
    private static let placeholder = "e.g. reviewing the checkout redesign with Sam"

    /// Only worth showing as the cap approaches; at 3/280 it is noise.
    private var showsCount: Bool {
        draft.count >= SessionContext.maxCharacters * 3 / 4
    }

    private var canSave: Bool {
        SessionContext.capped(draft) != controller.sessionContextText
    }

    private var canClear: Bool {
        controller.hasActiveSessionContext
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        controller.replaceSessionContext(fromEditedText: draft)
        draft = controller.sessionContextText
        now = Date()
        if closesAfterSave {
            dismiss()
        } else {
            flash(draft.isEmpty ? "Cleared" : "Saved")
        }
    }

    private func clear() {
        controller.clearSessionContext()
        draft = ""
        flash("Cleared")
    }

    /// A confirmation that never goes away stops reading as a confirmation.
    private func flash(_ message: String) {
        noteTask?.cancel()
        withAnimation { note = message }
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { note = nil }
        }
    }
}
