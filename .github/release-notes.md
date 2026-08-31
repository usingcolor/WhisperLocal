Apple Silicon only (M1 or later). Open the DMG and drag WhisperLocal into Applications.

<!-- The placeholder line below is replaced by .github/workflows/release.yml
     with the real signing state of this build. Do not hand-write it here. -->
{{SIGNING_SECTION}}

Then grant Microphone and Accessibility. Default ASR is Apple Speech on macOS 26 (Whisper / Parakeet are optional). Gemma 4 polish is optional (~2.7 GB) from Settings.

## 0.1.7

- **Cleanup is LLM-only.** The old heuristic rewrite is gone. Fillers (`um`, `uh`, `hmm`) still strip. False starts and “wait, no — actually” need Apple Intelligence (default on macOS 26), Gemma 4, or a cloud API key. On macOS 14–15, turn on Gemma or cloud polish for that cleanup.
- **Millimetres stay.** Spoken “5 mm” / “50 mm” is no longer treated as a filler pause.
- Cloud polish shows whether a key is saved, and On this Mac vs Cloud is a choice you can see at once.
- The menu bar shows the active polish model.
- Fix a dangling audio-buffer pointer on Bluetooth format changes.
