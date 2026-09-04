import Foundation
import os

/// Transcribes a long take while it is still being recorded.
///
/// Without this, everything waits until you let go: transcription costs about 6% of
/// realtime, so a thirty-minute take spent nearly two minutes on a spinner with no
/// way to abort. Here each completed chunk is transcribed during the pause that
/// follows it, and letting go only costs the final partial chunk.
///
/// It is a pipeline, not parallelism. One chunk is transcribed at a time while
/// capture continues on the audio thread, so nothing re-enters the speech services
/// and results stay in order for free.
@MainActor
final class StreamingTranscriber {
    private let recorder: AudioRecorder
    private let transcription: TranscriptionService
    private let dictionary: [String]
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "speech")

    private var parts: [String] = []
    private var loop: Task<Void, Never>?
    /// Audio already handed off, so the take's true length survives the draining.
    private(set) var streamedSamples = 0
    private(set) var completedChunks = 0

    /// How long to wait before asking for another chunk. Chunks arrive about once a
    /// minute, so this is idle almost all of the time.
    private let pollNanoseconds: UInt64 = 250_000_000

    init(recorder: AudioRecorder, transcription: TranscriptionService, dictionary: [String]) {
        self.recorder = recorder
        self.transcription = transcription
        self.dictionary = dictionary
    }

    func start(onChunk: @escaping (Int) -> Void) {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let chunk = self.recorder.drainCompletedChunk() else {
                    try? await Task.sleep(nanoseconds: self.pollNanoseconds)
                    continue
                }
                let seconds = Double(chunk.count) / 16_000
                let started = Date()
                let text = await self.transcribeWithRetry(chunk)
                // Chunk seconds against characters returned: separates "the drain
                // handed over a short chunk" from "ASR returned little for a full one".
                self.logger.info(
                    "Streamed chunk \(self.completedChunks + 1, privacy: .public): \(seconds, privacy: .public)s audio -> \(text.count, privacy: .public) chars in \(Date().timeIntervalSince(started), privacy: .public)s"
                )
                // Appended after the await on purpose: a chunk already in flight when
                // the take ends still counts, rather than being thrown away.
                self.parts.append(text)
                self.streamedSamples += chunk.count
                self.completedChunks += 1
                onChunk(self.completedChunks)
            }
        }
    }

    /// Stops the loop, lets any in-flight chunk finish, then transcribes the tail
    /// and returns the whole transcript.
    func finish(tail: [Float]) async -> String {
        loop?.cancel()
        await loop?.value
        loop = nil

        var all = parts
        if !tail.isEmpty {
            all.append(await transcribeWithRetry(tail))
        }
        return TranscriptJoiner.join(all)
    }

    func cancel() {
        loop?.cancel()
        loop = nil
        parts = []
        streamedSamples = 0
        completedChunks = 0
    }

    /// True once anything has been transcribed ahead of time. When false the take is
    /// short and the caller should transcribe it in one piece, exactly as before.
    var didStream: Bool { !parts.isEmpty }

    private func transcribeWithRetry(_ samples: [Float]) async -> String {
        do {
            return try await transcription.transcribe(samples: samples, extraDictionary: dictionary)
        } catch {
            logger.error("Streamed chunk failed, retrying: \(error.localizedDescription, privacy: .public)")
            do {
                return try await transcription.transcribe(samples: samples, extraDictionary: dictionary)
            } catch {
                logger.error("Streamed chunk failed twice: \(error.localizedDescription, privacy: .public)")
                // A gap, not a blank take. The rest of the recording still lands.
                return TranscriptJoiner.gapMarker
            }
        }
    }
}
