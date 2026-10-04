import Combine
import XCTest

private actor ContextSuspension {
    private var continuation: CheckedContinuation<Int, Never>?
    private var finished = false
    func run() async -> Int {
        if finished { return 1 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume(returning: 1)
        continuation = nil
    }
}

@MainActor
private final class ContextPolicy {
    @Published var enabled = true
    @Published var provider = "cloud"
}

@MainActor
final class AutoContextUpdateQueueTests: XCTestCase {
    func testUpdatesApplyInDictationOrder() async {
        let queue = AutoContextUpdateQueue()
        let blocked = ContextSuspension()
        let started = expectation(description: "first request started")
        let finished = expectation(description: "second update applied")
        var requested: [Int] = []
        var applied: [Int] = []
        queue.enqueue(generation: queue.generation, operation: {
            requested.append(1)
            started.fulfill()
            return await blocked.run()
        }, apply: { applied.append($0) })
        queue.enqueue(generation: queue.generation, operation: {
            requested.append(2)
            return 2
        }, apply: { applied.append($0); finished.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(requested, [1])
        XCTAssertTrue(applied.isEmpty)
        await blocked.finish()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(requested, [1, 2])
        XCTAssertEqual(applied, [1, 2])
    }

    func testDisablingPolicyCancelsTheRequestAndDropsQueuedWorkAndLateAnswers() async {
        let queue = AutoContextUpdateQueue()
        let policy = ContextPolicy()
        queue.invalidateWhenChanged(policy.$enabled)
        let blocked = ContextSuspension()
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "running request was cancelled")
        let unwanted = expectation(description: "revoked request or answer")
        unwanted.isInverted = true
        queue.enqueue(generation: queue.generation, operation: {
            started.fulfill()
            let answer = await blocked.run()
            if Task.isCancelled { cancelled.fulfill() }
            return answer
        }, apply: { _ in unwanted.fulfill() })
        queue.enqueue(generation: queue.generation, operation: {
            unwanted.fulfill()
            return 2
        }, apply: { _ in unwanted.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        policy.enabled = false
        await blocked.finish()
        await fulfillment(of: [cancelled], timeout: 1)
        await fulfillment(of: [unwanted], timeout: 0.05)
    }

    func testRapidOffOnRejectsATakeCapturedBeforeRevocation() async {
        let queue = AutoContextUpdateQueue()
        let policy = ContextPolicy()
        queue.invalidateWhenChanged(policy.$enabled)
        let beforePolish = queue.generation
        policy.enabled = false
        policy.enabled = true
        let unwanted = expectation(description: "old take must not send")
        unwanted.isInverted = true
        queue.enqueue(generation: beforePolish, operation: {
            unwanted.fulfill()
            return 1
        }, apply: { _ in unwanted.fulfill() })
        let fresh = expectation(description: "new take applied")
        queue.enqueue(generation: queue.generation, operation: { 2 }, apply: { _ in fresh.fulfill() })
        await fulfillment(of: [fresh], timeout: 1)
        await fulfillment(of: [unwanted], timeout: 0.05)
    }

    func testProviderChangeInvalidatesTheOldPolicySynchronously() {
        let queue = AutoContextUpdateQueue()
        let policy = ContextPolicy()
        queue.invalidateWhenChanged(policy.$provider)
        let old = queue.generation
        policy.provider = "local"
        XCTAssertFalse(queue.isCurrent(old))
        XCTAssertTrue(queue.isCurrent(queue.generation))
    }

    func testClearStartsFreshWorkWithoutWaitingForANoncooperativeRequest() async {
        let queue = AutoContextUpdateQueue()
        let blocked = ContextSuspension()
        let started = expectation(description: "old request started")
        let oldReturned = expectation(description: "old request returned")
        let unwanted = expectation(description: "old answer applied")
        unwanted.isInverted = true
        queue.enqueue(generation: queue.generation, operation: {
            started.fulfill()
            let answer = await blocked.run()
            oldReturned.fulfill()
            return answer
        }, apply: { _ in unwanted.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        queue.invalidate()
        let fresh = expectation(description: "fresh update applied")
        queue.enqueue(generation: queue.generation, operation: { 2 }, apply: { _ in fresh.fulfill() })
        await fulfillment(of: [fresh], timeout: 1)
        await blocked.finish()
        await fulfillment(of: [oldReturned], timeout: 1)
        await fulfillment(of: [unwanted], timeout: 0.05)
    }

    func testAnOldWorkerCannotDetachTheReplacementWorker() async {
        let queue = AutoContextUpdateQueue()
        let old = ContextSuspension()
        let replacement = ContextSuspension()
        let oldStarted = expectation(description: "old request started")
        let oldReturned = expectation(description: "old request returned")
        let replacementStarted = expectation(description: "replacement started")
        let thirdApplied = expectation(description: "third update applied")
        let premature = expectation(description: "third request ran ahead of replacement")
        premature.isInverted = true
        var allowThird = false
        var applied: [Int] = []
        queue.enqueue(generation: queue.generation, operation: {
            oldStarted.fulfill()
            let answer = await old.run()
            oldReturned.fulfill()
            return answer
        }, apply: { applied.append($0) })
        await fulfillment(of: [oldStarted], timeout: 1)
        queue.invalidate()
        queue.enqueue(generation: queue.generation, operation: {
            replacementStarted.fulfill()
            _ = await replacement.run()
            return 2
        }, apply: { applied.append($0) })
        await fulfillment(of: [replacementStarted], timeout: 1)
        await old.finish()
        await fulfillment(of: [oldReturned], timeout: 1)
        queue.enqueue(generation: queue.generation, operation: {
            if !allowThird { premature.fulfill() }
            return 3
        }, apply: { applied.append($0); thirdApplied.fulfill() })
        await fulfillment(of: [premature], timeout: 0.05)
        allowThird = true
        await replacement.finish()
        await fulfillment(of: [thirdApplied], timeout: 1)
        XCTAssertEqual(applied, [2, 3])
    }
}
