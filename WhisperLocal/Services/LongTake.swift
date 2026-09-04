import Foundation

/// How long a single take may run, and how it is broken up once it gets long.
///
/// The app used to have no ceiling at all: the capture buffer grew until you let
/// go, and a long take then went to ASR in one piece — so a single failure lost
/// everything you had just said. These limits exist so a long take degrades into
/// *some* text rather than a blank paste.
enum TakeLimits {
    /// Auto-finish here. This stops the take and transcribes it; it never discards.
    static let maxSeconds: TimeInterval = 10 * 60
    /// Show the countdown once this much time is left.
    static let warnSeconds: TimeInterval = 60
    /// Longer than this goes through the chunked path.
    static let chunkAboveSeconds: TimeInterval = 120

    static func remaining(elapsed: TimeInterval) -> TimeInterval {
        max(0, maxSeconds - elapsed)
    }

    static func shouldAutoStop(elapsed: TimeInterval) -> Bool {
        elapsed >= maxSeconds
    }

    static func shouldChunk(seconds: TimeInterval) -> Bool {
        seconds > chunkAboveSeconds
    }

    /// `nil` until the take is close to the ceiling — a countdown that runs the
    /// whole time is just a stopwatch, and reads as pressure rather than warning.
    static func countdownLabel(elapsed: TimeInterval) -> String? {
        let left = remaining(elapsed: elapsed)
        guard left <= warnSeconds else { return nil }
        let whole = Int(left.rounded(.up))
        if whole <= 0 { return "Stopping now" }
        return "Auto-stops in \(whole)s"
    }

    static func limitNote(seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "Reached the \(minutes)-minute limit — transcribing what you said."
    }
}

/// Splits long audio into pieces ASR can be retried on independently.
///
/// Cuts land on the quietest point near each boundary rather than at a fixed
/// offset, so a chunk edge usually falls between words. That is why there is no
/// overlap here: overlapping windows need word-level de-duplication on the way
/// out, which drops genuinely repeated words.
enum AudioChunker {
    static let targetSeconds: Double = 60
    /// How far either side of a target boundary to hunt for quiet.
    static let searchSeconds: Double = 2
    /// Window used to measure quiet. About one syllable.
    static let probeSeconds: Double = 0.02

    /// Boundary planning only — no samples needed, so the arithmetic is testable
    /// on its own.
    static func plan(
        sampleCount: Int,
        sampleRate: Double,
        targetSeconds: Double = targetSeconds
    ) -> [Range<Int>] {
        guard sampleCount > 0, sampleRate > 0, targetSeconds > 0 else { return [] }
        let target = max(1, Int(targetSeconds * sampleRate))
        guard sampleCount > target else { return [0..<sampleCount] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + target, sampleCount)
            ranges.append(start..<end)
            start = end
        }
        // A sliver on the end transcribes poorly and is rarely worth its own
        // request; fold it back into the chunk before it.
        if ranges.count >= 2, let last = ranges.last, last.count < target / 4 {
            ranges.removeLast()
            let prev = ranges.removeLast()
            ranges.append(prev.lowerBound..<last.upperBound)
        }
        return ranges
    }

    /// Cut point for the first complete chunk of a *growing* buffer, or nil while
    /// there is not enough audio to place one.
    ///
    /// Streaming cannot use `plan`/`refine`, which need the whole take up front. It
    /// needs `target + search` seconds before cutting so the quiet search still has
    /// audio on both sides of the boundary — which is why the cut trails live audio
    /// by a couple of seconds. Nobody sees that: it happens while you are still
    /// talking.
    static func streamingCut(
        in samples: [Float],
        sampleRate: Double,
        targetSeconds: Double = targetSeconds,
        searchSeconds: Double = searchSeconds
    ) -> Int? {
        guard sampleRate > 0, targetSeconds > 0 else { return nil }
        let target = Int(targetSeconds * sampleRate)
        let search = max(1, Int(searchSeconds * sampleRate))
        let probe = max(1, Int(probeSeconds * sampleRate))
        // Enough audio to look both ways around the boundary, and to take a probe
        // window at the far end of the search.
        guard samples.count >= target + search + probe else { return nil }

        let lower = max(probe, target - search)
        let upper = min(samples.count - probe, target + search)
        guard lower < upper else { return nil }
        return quietestOffset(in: samples, from: lower, to: upper, probe: probe)
    }

    /// Move each interior boundary to the quietest nearby window.
    static func refine(
        _ ranges: [Range<Int>],
        in samples: [Float],
        sampleRate: Double,
        searchSeconds: Double = searchSeconds
    ) -> [Range<Int>] {
        guard ranges.count > 1, sampleRate > 0 else { return ranges }
        let search = max(1, Int(searchSeconds * sampleRate))
        let probe = max(1, Int(probeSeconds * sampleRate))

        var cuts: [Int] = []
        for range in ranges.dropLast() {
            let target = range.upperBound
            let lower = max(cuts.last.map { $0 + probe } ?? probe, target - search)
            let upper = min(samples.count - probe, target + search)
            cuts.append(lower >= upper ? target : quietestOffset(in: samples, from: lower, to: upper, probe: probe))
        }

        var out: [Range<Int>] = []
        var start = 0
        for cut in cuts where cut > start {
            out.append(start..<cut)
            start = cut
        }
        if start < samples.count { out.append(start..<samples.count) }
        return out.isEmpty ? ranges : out
    }

    private static func quietestOffset(in samples: [Float], from lower: Int, to upper: Int, probe: Int) -> Int {
        var bestOffset = lower
        var bestEnergy = Float.greatestFiniteMagnitude
        // Coarse hop: sampling every probe window is plenty to find a pause and
        // keeps this linear in the search span, not the take.
        var offset = lower
        while offset < upper {
            var energy: Float = 0
            for i in offset..<min(offset + probe, samples.count) {
                energy += abs(samples[i])
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestOffset = offset
            }
            offset += probe
        }
        return bestOffset
    }
}

/// Joins per-chunk transcripts back into one string.
enum TranscriptJoiner {
    /// Placeholder for a chunk that could not be transcribed even after a retry.
    /// A visible gap is honest; silently closing it invents continuity.
    static let gapMarker = "…"

    static func join(_ parts: [String]) -> String {
        var pieces: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Don't stack markers when several chunks in a row fail.
            if trimmed == gapMarker, pieces.last == gapMarker { continue }
            pieces.append(trimmed)
        }
        guard !pieces.isEmpty else { return "" }

        // Chunks are cut at silence, so a plain space is the right seam whether or
        // not the previous piece ended a sentence. Polish fixes the casing after.
        return pieces.joined(separator: " ")
    }
}
