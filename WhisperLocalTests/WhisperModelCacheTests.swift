import XCTest

/// A model already on disk has to load with the network off. These cover finding
/// it where WhisperKit's download put it, and not mistaking a partial download for
/// a usable one.
final class WhisperModelCacheTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var repoFolder: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
    }

    @discardableResult
    private func makeModel(_ folderName: String, files: [String] = WhisperModelCache.requiredFiles) throws -> URL {
        let folder = repoFolder.appendingPathComponent(folderName)
        for file in files {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(file),
                withIntermediateDirectories: true
            )
        }
        return folder
    }

    func testFindsACompleteModel() throws {
        let folder = try makeModel("openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(
            WhisperModelCache.folder(for: "large-v3-v20240930_turbo", downloadBase: base)?.standardizedFileURL,
            folder.standardizedFileURL
        )
    }

    func testNothingDownloadedIsAMiss() {
        XCTAssertNil(WhisperModelCache.folder(for: "small.en", downloadBase: base))
        XCTAssertNil(WhisperModelCache.folder(
            for: "small.en",
            downloadBase: base.appendingPathComponent("missing")
        ))
    }

    /// An interrupted download leaves a folder behind. Loading it would fail, and
    /// skipping the download means it would never be repaired.
    func testAPartialDownloadIsAMiss() throws {
        try makeModel("openai_whisper-small.en", files: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"])
        XCTAssertNil(WhisperModelCache.folder(for: "small.en", downloadBase: base))
    }

    /// Mirrors WhisperKit's own disambiguation, so the folder found is the one it
    /// would have downloaded.
    func testPrefersTheOpenAIFolderWhenSeveralMatch() throws {
        let openAI = try makeModel("openai_whisper-small.en")
        try makeModel("distil-whisper_distil-small.en")
        XCTAssertEqual(
            WhisperModelCache.folder(for: "small.en", downloadBase: base)?.standardizedFileURL,
            openAI.standardizedFileURL
        )
    }

    /// `large-v3-v20240930_turbo` must not pick up a different size of the same model.
    func testOtherVariantsDoNotMatch() throws {
        try makeModel("openai_whisper-large-v3-v20240930_turbo_632MB")
        XCTAssertNil(WhisperModelCache.folder(for: "large-v3-v20240930_turbo", downloadBase: base))
    }
}
