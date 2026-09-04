import XCTest


final class TakeLimitsTests: XCTestCase {
    func testCountdownStaysHiddenUntilTheEnd() {
        XCTAssertNil(TakeLimits.countdownLabel(elapsed: 0))
        XCTAssertNil(TakeLimits.countdownLabel(elapsed: 60))
        // Warn window opens exactly `warnSeconds` before the ceiling.
        let opensAt = TakeLimits.maxSeconds - TakeLimits.warnSeconds
        XCTAssertNil(TakeLimits.countdownLabel(elapsed: opensAt - 1))
        XCTAssertNotNil(TakeLimits.countdownLabel(elapsed: opensAt))
    }

    func testCountdownCountsDown() {
        XCTAssertEqual(TakeLimits.countdownLabel(elapsed: TakeLimits.maxSeconds - 30), "Auto-stops in 30s")
        XCTAssertEqual(TakeLimits.countdownLabel(elapsed: TakeLimits.maxSeconds - 1), "Auto-stops in 1s")
        XCTAssertEqual(TakeLimits.countdownLabel(elapsed: TakeLimits.maxSeconds), "Stopping now")
    }

    func testAutoStopAndRemainingNeverGoNegative() {
        XCTAssertFalse(TakeLimits.shouldAutoStop(elapsed: TakeLimits.maxSeconds - 0.1))
        XCTAssertTrue(TakeLimits.shouldAutoStop(elapsed: TakeLimits.maxSeconds))
        XCTAssertTrue(TakeLimits.shouldAutoStop(elapsed: TakeLimits.maxSeconds * 10))
        XCTAssertEqual(TakeLimits.remaining(elapsed: TakeLimits.maxSeconds * 10), 0)
    }

    func testOnlyLongTakesAreChunked() {
        XCTAssertFalse(TakeLimits.shouldChunk(seconds: 30))
        XCTAssertFalse(TakeLimits.shouldChunk(seconds: TakeLimits.chunkAboveSeconds))
        XCTAssertTrue(TakeLimits.shouldChunk(seconds: TakeLimits.chunkAboveSeconds + 1))
    }
}

final class AudioChunkerTests: XCTestCase {
    private let rate: Double = 16_000

    func testShortAudioIsOneChunk() {
        let n = Int(rate * 30)
        XCTAssertEqual(AudioChunker.plan(sampleCount: n, sampleRate: rate), [0..<n])
    }

    func testChunksCoverEverySampleExactlyOnce() {
        let n = Int(rate * 617)   // deliberately not a multiple of the target
        let ranges = AudioChunker.plan(sampleCount: n, sampleRate: rate)
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, n)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "chunks must not gap or overlap")
        }
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, n)
    }

    func testTrailingSliverIsFoldedBack() {
        // One second past a clean multiple would otherwise be its own chunk.
        let n = Int(rate * 121)
        let ranges = AudioChunker.plan(sampleCount: n, sampleRate: rate, targetSeconds: 60)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.last?.upperBound, n)
        XCTAssertGreaterThan(ranges.last!.count, Int(rate * 60))
    }

    func testDegenerateInputs() {
        XCTAssertEqual(AudioChunker.plan(sampleCount: 0, sampleRate: rate), [])
        XCTAssertEqual(AudioChunker.plan(sampleCount: 100, sampleRate: 0), [])
        XCTAssertEqual(AudioChunker.plan(sampleCount: 100, sampleRate: rate, targetSeconds: 0), [])
    }

    func testRefineMovesTheCutIntoSilence() {
        // 120s of tone with a deliberate silent gap 3s before the 60s boundary.
        let n = Int(rate * 120)
        var samples = [Float](repeating: 0.5, count: n)
        let gapStart = Int(rate * 57)
        let gapEnd = Int(rate * 57.5)
        for i in gapStart..<gapEnd { samples[i] = 0 }

        let planned = AudioChunker.plan(sampleCount: n, sampleRate: rate)
        let refined = AudioChunker.refine(planned, in: samples, sampleRate: rate, searchSeconds: 4)

        XCTAssertEqual(refined.count, planned.count)
        let cut = refined[0].upperBound
        XCTAssertGreaterThanOrEqual(cut, gapStart, "cut should land inside the silence")
        XCTAssertLessThanOrEqual(cut, gapEnd)
        // Still a complete, contiguous cover.
        XCTAssertEqual(refined.first?.lowerBound, 0)
        XCTAssertEqual(refined.last?.upperBound, n)
        for (a, b) in zip(refined, refined.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound)
        }
    }

    func testRefineLeavesASingleChunkAlone() {
        let n = Int(rate * 30)
        let samples = [Float](repeating: 0.5, count: n)
        let planned = AudioChunker.plan(sampleCount: n, sampleRate: rate)
        XCTAssertEqual(AudioChunker.refine(planned, in: samples, sampleRate: rate), planned)
    }
}

final class TranscriptJoinerTests: XCTestCase {
    func testJoinsWithSingleSpaces() {
        XCTAssertEqual(TranscriptJoiner.join(["one two", "  three four  "]), "one two three four")
    }

    func testSkipsEmptyChunks() {
        XCTAssertEqual(TranscriptJoiner.join(["alpha", "", "   ", "beta"]), "alpha beta")
        XCTAssertEqual(TranscriptJoiner.join([]), "")
        XCTAssertEqual(TranscriptJoiner.join(["", "  "]), "")
    }

    func testConsecutiveGapsCollapseToOne() {
        let g = TranscriptJoiner.gapMarker
        XCTAssertEqual(TranscriptJoiner.join(["alpha", g, g, "beta"]), "alpha \(g) beta")
    }

    func testASingleFailedChunkStillLeavesTheRest() {
        let g = TranscriptJoiner.gapMarker
        let joined = TranscriptJoiner.join(["the meeting is", g, "on Friday"])
        XCTAssertTrue(joined.contains("the meeting is"))
        XCTAssertTrue(joined.contains("on Friday"))
        XCTAssertFalse(joined.isEmpty, "a failed chunk must never blank the take")
    }
}

final class PolishChunkerTests: XCTestCase {
    func testShortTextIsOnePiece() {
        XCTAssertEqual(PolishChunker.split("Hello there."), ["Hello there."])
        XCTAssertEqual(PolishChunker.split("   "), [])
        XCTAssertEqual(PolishChunker.split(""), [])
    }

    func testSplitsOnSentenceBoundariesUnderBudget() {
        let sentence = String(repeating: "word ", count: 20) + "end."
        let text = String(repeating: sentence + " ", count: 40)
        let pieces = PolishChunker.split(text, budget: 500)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 500)
            XCTAssertTrue(piece.hasSuffix("end."), "pieces should end on a sentence")
        }
    }

    func testNothingIsLost() {
        let text = String(repeating: "alpha beta gamma delta. ", count: 300)
        let pieces = PolishChunker.split(text, budget: 400)
        let rejoined = pieces.joined(separator: " ")
        let normalize = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertEqual(normalize(rejoined), normalize(text), "splitting must not drop or reorder words")
    }

    func testUnpunctuatedDictationStillBreaksOnWords() {
        // Continuous dictation with no sentence punctuation at all.
        let text = String(repeating: "word ", count: 2_000)
        let pieces = PolishChunker.split(text, budget: 300)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 300)
            XCTAssertFalse(piece.hasPrefix("ord"), "must not cut mid-word")
            XCTAssertFalse(piece.hasSuffix("wor"), "must not cut mid-word")
        }
        let normalize = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertEqual(normalize(pieces.joined(separator: " ")), normalize(text))
    }

    func testSingleTokenLongerThanBudgetIsNotLost() {
        let giant = String(repeating: "x", count: 900)
        let pieces = PolishChunker.split(giant, budget: 300)
        XCTAssertEqual(pieces.joined(), giant)
    }
}

final class StreamingCutTests: XCTestCase {
    private let rate: Double = 16_000

    func testWaitsUntilThereIsEnoughAudioToLookBothWays() {
        // A full target's worth is not enough on its own: the quiet search needs
        // audio *after* the boundary too.
        let justTarget = [Float](repeating: 0.5, count: Int(rate * AudioChunker.targetSeconds))
        XCTAssertNil(AudioChunker.streamingCut(in: justTarget, sampleRate: rate))

        let enough = [Float](repeating: 0.5, count: Int(rate * (AudioChunker.targetSeconds + AudioChunker.searchSeconds + 1)))
        XCTAssertNotNil(AudioChunker.streamingCut(in: enough, sampleRate: rate))
    }

    func testCutsAtSilenceNearTheBoundary() {
        let n = Int(rate * 70)
        var samples = [Float](repeating: 0.5, count: n)
        // Quiet gap just before the 60s target.
        let gapStart = Int(rate * 58.5)
        let gapEnd = Int(rate * 59.0)
        for i in gapStart..<gapEnd { samples[i] = 0 }

        let cut = AudioChunker.streamingCut(in: samples, sampleRate: rate, searchSeconds: 4)
        XCTAssertNotNil(cut)
        XCTAssertGreaterThanOrEqual(cut!, gapStart)
        XCTAssertLessThanOrEqual(cut!, gapEnd)
    }

    func testCutIsAlwaysInsideTheBuffer() {
        for seconds in [63.0, 80.0, 121.0, 200.0] {
            let samples = [Float](repeating: 0.2, count: Int(rate * seconds))
            guard let cut = AudioChunker.streamingCut(in: samples, sampleRate: rate) else { continue }
            XCTAssertGreaterThan(cut, 0)
            XCTAssertLessThan(cut, samples.count, "a cut at the end would emit the whole buffer")
        }
    }

    func testDegenerateInputs() {
        XCTAssertNil(AudioChunker.streamingCut(in: [], sampleRate: rate))
        XCTAssertNil(AudioChunker.streamingCut(in: [Float](repeating: 0, count: 100), sampleRate: 0))
        XCTAssertNil(AudioChunker.streamingCut(in: [Float](repeating: 0, count: 10_000_000), sampleRate: rate, targetSeconds: 0))
    }

    func testRepeatedCutsWalkForwardAndCoverEverything() {
        // Simulate the drain loop: cut, drop the prefix, repeat.
        var remaining = [Float](repeating: 0.3, count: Int(rate * 200))
        let original = remaining.count
        var emitted = 0
        var pieces = 0
        while let cut = AudioChunker.streamingCut(in: remaining, sampleRate: rate) {
            XCTAssertGreaterThan(cut, 0)
            emitted += cut
            remaining.removeFirst(cut)
            pieces += 1
            XCTAssertLessThan(pieces, 20, "loop must terminate")
        }
        XCTAssertGreaterThan(pieces, 1)
        XCTAssertEqual(emitted + remaining.count, original, "no samples lost or duplicated")
    }
}
