import XCTest

@MainActor
final class StreamingTranscriberTests: XCTestCase {
    func testStopWaitsForTheFirstDrainedChunkAndKeepsTheTail() async {
        let started = expectation(description: "first ASR request started")
        var pending: CheckedContinuation<String, Error>?
        var chunks: [[Float]] = [[1, 2, 3]]
        var requests: [[Float]] = []
        let streamer = StreamingTranscriber(
            drainChunk: { chunks.isEmpty ? nil : chunks.removeFirst() },
            transcribe: { samples, _, _ in
                requests.append(samples)
                if requests.count == 1 {
                    return try await withCheckedThrowingContinuation {
                        pending = $0
                        started.fulfill()
                    }
                }
                return "tail"
            }, dictionary: []
        )
        streamer.start()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(streamer.didStream, "audio is already drained even before ASR answers")
        XCTAssertEqual(streamer.streamedSamples, 3)
        let finish = Task { await streamer.finish(tail: [4, 5]) }
        await Task.yield()
        pending?.resume(returning: "first chunk")
        let output = await finish.value
        XCTAssertEqual(output, "first chunk tail")
        XCTAssertEqual(requests, [[1, 2, 3], [4, 5]])
    }

    func testCancelDiscardsALateResultAndDoesNotRetry() async {
        let started = expectation(description: "ASR started")
        var pending: CheckedContinuation<String, Error>?
        var chunks: [[Float]] = [[1]]
        var calls = 0
        let streamer = StreamingTranscriber(
            drainChunk: { chunks.isEmpty ? nil : chunks.removeFirst() },
            transcribe: { _, _, _ in
                calls += 1
                return try await withCheckedThrowingContinuation {
                    pending = $0
                    started.fulfill()
                }
            }, dictionary: []
        )
        streamer.start()
        await fulfillment(of: [started], timeout: 1)
        streamer.cancel()
        pending?.resume(throwing: CancellationError())
        await Task.yield()
        XCTAssertFalse(streamer.didStream)
        XCTAssertEqual(streamer.completedChunks, 0)
        XCTAssertEqual(calls, 1)
    }
}
