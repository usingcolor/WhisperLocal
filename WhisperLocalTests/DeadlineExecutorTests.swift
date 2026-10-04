import XCTest

private actor SuspendedWork {
    private var continuation: CheckedContinuation<Int, Never>?
    private var finished = false
    func run() async -> Int {
        if finished { return 42 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(returning: 42); continuation = nil }
}

final class DeadlineExecutorTests: XCTestCase {
    func testSuccessfulRequestsReleaseTheSlotBeforeReturning() async throws {
        let executor = DeadlineExecutor()
        let first = try await executor.run(seconds: 1) { 42 }
        let second = try await executor.run(seconds: 1) { 99 }
        XCTAssertEqual(first, 42)
        XCTAssertEqual(second, 99)
    }

    func testDeadlineReturnsWithoutWaitingForNoncooperativeWork() async throws {
        let executor = DeadlineExecutor()
        let work = SuspendedWork()
        let start = Date()
        do {
            _ = try await executor.run(seconds: 0.05) { await work.run() }
            XCTFail("a suspended worker must time out")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        do {
            _ = try await executor.run(seconds: 1) { 99 }
            XCTFail("must not accumulate workers while the abandoned request is running")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("still finishing"))
        }
        await work.finish()
    }

    func testCancellationReturnsWhileWorkerIsStillSuspended() async {
        let executor = DeadlineExecutor()
        let work = SuspendedWork()
        let started = expectation(description: "worker started")
        let task = Task {
            try await executor.run(seconds: 10) {
                started.fulfill()
                return await work.run()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled operation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        await work.finish()
    }
}
