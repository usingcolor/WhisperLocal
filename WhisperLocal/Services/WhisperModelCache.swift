import Foundation

/// Finds a WhisperKit model already on disk, so loading it needs no network.
///
/// Given only a model name, WhisperKit asks the Hub which files to fetch before it
/// looks at its own cache, and that call throws offline even when every file is
/// already here. Handing WhisperKit the folder directly skips the Hub entirely.
enum WhisperModelCache {
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Where WhisperKit's Hub client keeps downloads when no base is given. Passed
    /// to WhisperKit explicitly so the lookup and the download can never disagree.
    static var defaultDownloadBase: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface")
    }

    /// Without these WhisperKit cannot load the model, so a folder missing any of
    /// them is an interrupted download, not a cache hit.
    static let requiredFiles = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// The cached folder for `variant` under `downloadBase`, or nil when there is
    /// no complete one.
    ///
    /// Matches folders the way WhisperKit's download does (`*<variant>`) and, as it
    /// does, falls back to the `openai` prefix when that is ambiguous, so a model
    /// is found under the same folder it was downloaded to.
    static func folder(
        for variant: String,
        downloadBase: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let repoFolder = downloadBase.appendingPathComponent("models/\(repo)")
        guard let names = try? fileManager.contentsOfDirectory(atPath: repoFolder.path) else {
            return nil
        }

        var matches = names.filter { $0.hasSuffix(variant) }
        if matches.count > 1 {
            matches = matches.filter { $0.hasPrefix("openai") }
        }
        guard matches.count == 1 else { return nil }

        let folder = repoFolder.appendingPathComponent(matches[0])
        let complete = requiredFiles.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return complete ? folder : nil
    }
}
