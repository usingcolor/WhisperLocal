import Combine
import Foundation

/// Serial background work that can be forgotten without waiting for a model
/// that ignores cancellation. A new generation never joins the old worker.
@MainActor
final class AutoContextUpdateQueue {
    private(set) var generation = UUID()
    private var pending: [@MainActor () async -> Void] = []
    private var worker: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    func isCurrent(_ generation: UUID) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    func invalidate() {
        generation = UUID()
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    /// Published delivers synchronously, so even off → on in one run-loop turn
    /// revokes the old work. This also covers a take still being polished.
    func invalidateWhenChanged<Value>(
        _ publisher: Published<Value>.Publisher,
        onChange: @escaping @MainActor (Value) -> Void = { _ in }
    ) {
        publisher.dropFirst()
            .sink { [weak self] value in
                self?.invalidate()
                onChange(value)
            }
            .store(in: &observations)
    }

    func enqueue<Value: Sendable>(
        generation: UUID,
        operation: @escaping @MainActor () async -> Value,
        apply: @escaping @MainActor (Value) -> Void
    ) {
        guard isCurrent(generation) else { return }
        pending.append { [weak self] in
            guard self?.isCurrent(generation) == true else { return }
            let value = await operation()
            guard self?.isCurrent(generation) == true else { return }
            apply(value)
        }
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isCurrent(generation), !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                await next()
            }
            // An obsolete worker must not clear the replacement worker's handle.
            if self.generation == generation { self.worker = nil }
        }
    }
}
