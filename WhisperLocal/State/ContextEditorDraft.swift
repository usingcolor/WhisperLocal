import Foundation

/// A window owns its draft. Saving applies only changed identities against the
/// latest context, so a background update or a new Shift take cannot be lost.
struct ContextEditorDraft: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: UUID
        var text: String
        let source: AutoContext.Topic.Source
        let detail: String
    }

    private(set) var baseline: [Entry]
    var entries: [Entry]

    init(session: SessionContext?, topics: [AutoContext.Topic], now: Date = Date()) {
        var rows: [Entry] = []
        if let session, !session.isExpired(now: now) {
            rows.append(Entry(id: session.id, text: session.text, source: .shift,
                              detail: "Clears after 45 min idle or 3 unrelated takes"))
        }
        rows += topics.filter { !$0.source.isAutomatic }.map {
            Entry(id: $0.id, text: $0.text, source: $0.source, detail: "Until removed or app quits")
        }
        rows += AutoContext.newestFirst(topics.filter { $0.source.isAutomatic }).map {
            Entry(id: $0.id, text: $0.text, source: .automatic, detail: AutoContext.whereAndWhen($0, now: now))
        }
        baseline = rows
        entries = rows
    }

    var isDirty: Bool {
        entries.map { ($0.id, $0.text) }.elementsEqual(baseline.map { ($0.id, $0.text) }, by: ==) == false
    }

    mutating func addNote() -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, text: "", source: .typed, detail: "Until removed or app quits"))
        return id
    }

    /// Nil means the edit would exceed the protected-note budget. No partial
    /// mutation escapes; the caller can leave the user's draft intact.
    func applying(to context: AutoContext, session: SessionContext?, now: Date = Date()) -> (AutoContext, SessionContext?)? {
        var next = context
        var spoken = session
        for removed in baseline where !entries.contains(where: { $0.id == removed.id }) {
            if removed.source == .shift {
                if spoken?.id == removed.id { spoken = nil }
            } else {
                next.remove(id: removed.id)
            }
        }
        for entry in entries {
            guard !baseline.contains(where: { $0.id == entry.id && $0.text == entry.text }) else { continue }
            let text = SessionContext.capped(entry.text)
            if entry.source == .shift, spoken?.id == entry.id {
                if text.isEmpty { spoken = nil }
                else { spoken = SessionContext.make(text: text, now: now); spoken?.id = entry.id }
            } else {
                // A newer Shift take has a new ID; preserve it and save the
                // edited old phrase as a note alongside it.
                let source: AutoContext.Topic.Source = entry.source == .automatic ? .edited : (entry.source == .shift ? .typed : entry.source)
                next.setUserTopic(id: entry.id, text: text, source: source, now: now)
            }
        }
        guard next.userTopics.count <= AutoContext.maxUserTopics else { return nil }
        return (next, spoken)
    }
}
