import SwiftUI

struct SessionContextEditor: View {
    @ObservedObject var controller: DictationController
    var showsIntro: Bool = false

    @State private var draft = ""
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsIntro {
                Text("Session context")
                    .font(.headline)
                Text("Used on later dictations for names and jargon. A spoken take is distilled into a short topic, then stored — nothing is pasted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Current phrase")
                    .font(.subheadline)
            }
            TextField("I’m writing the MambaEye paper…", text: $draft, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Text("\(draft.count)/\(SessionContext.maxCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Save") { save() }
                    .disabled(!canSave)
                Button("Clear", role: .destructive) { clear() }
                    .disabled(!canClear)
            }
        }
        .onAppear { draft = controller.sessionContextText }
        .onChange(of: controller.sessionContext) { _, _ in
            draft = controller.sessionContextText
        }
        .onChange(of: draft) { _, newValue in
            if newValue.count > SessionContext.maxCharacters {
                let end = newValue.index(newValue.startIndex, offsetBy: SessionContext.maxCharacters)
                draft = String(newValue[..<end])
            }
        }
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
        note = draft.isEmpty ? "Cleared" : "Saved"
    }

    private func clear() {
        controller.clearSessionContext()
        draft = ""
        note = "Cleared"
    }
}
