import Foundation

/// Returns at the deadline even when a model ignores cancellation. A timed-out
/// worker retains the slot until it finishes, bounding abandoned work to one.
final class DeadlineExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard claim() else {
            throw PolisherError.notAvailable("The previous on-device request is still finishing.")
        }
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let worker = Task {
                    let result: Result<T, Error>
                    do {
                        try Task.checkCancellation()
                        result = .success(try await operation())
                    } catch { result = .failure(error) }
                    self.release()
                    race.finish(result)
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(max(0, seconds))) }
                    catch { return }
                    race.finish(.failure(PolisherError.notAvailable("On-device polish timed out.")))
                }
                race.install(worker: worker, timer: timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func release() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func install(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished {
            self.worker = worker
            self.timer = timer
        }
        lock.unlock()
        if finished { worker.cancel(); timer.cancel() }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        let worker = worker
        let timer = timer
        self.continuation = nil
        self.worker = nil
        self.timer = nil
        lock.unlock()
        worker?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
