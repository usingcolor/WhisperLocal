import Foundation

/// Spoken, in-memory polish context. Not persisted — expiry is the point.
struct SessionContext: Equatable, Sendable {
    var text: String
    var setAt: Date
    var lastUsedAt: Date
    var driftStrikes: Int

    /// Same order of magnitude as `CleanupPrompt.cloudRecentMaxCharsPerSide`.
    static let maxCharacters = 280
    static let idleExpiry: TimeInterval = 45 * 60
    static let strikesToClear = 3

    static func make(text: String, now: Date = Date()) -> SessionContext? {
        let capped = Self.capped(text)
        guard !capped.isEmpty else { return nil }
        return SessionContext(text: capped, setAt: now, lastUsedAt: now, driftStrikes: 0)
    }

    static func capped(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isExpired(_ context: SessionContext, now: Date) -> Bool {
        now.timeIntervalSince(context.lastUsedAt) >= idleExpiry
    }

    static func registerUse(_ context: SessionContext, now: Date) -> SessionContext {
        var next = context
        next.lastUsedAt = now
        return next
    }

    /// Three consecutive unrelated takes clear the context. One or two asides keep it.
    static func registerJudgment(_ context: SessionContext, relevant: Bool) -> SessionContext? {
        var next = context
        if relevant {
            next.driftStrikes = 0
            return next
        }
        next.driftStrikes += 1
        if next.driftStrikes >= strikesToClear {
            return nil
        }
        return next
    }

    func isExpired(now: Date) -> Bool {
        Self.isExpired(self, now: now)
    }

    func registerUse(now: Date) -> SessionContext {
        Self.registerUse(self, now: now)
    }

    func registerJudgment(relevant: Bool) -> SessionContext? {
        Self.registerJudgment(self, relevant: relevant)
    }
}
