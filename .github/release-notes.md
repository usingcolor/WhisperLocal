Apple Silicon only (M1 or later). Open the DMG and drag WhisperLocal into Applications.

<!-- The placeholder line below is replaced by .github/workflows/release.yml
     with the real signing state of this build. Do not hand-write it here. -->
{{SIGNING_SECTION}}

Then grant Microphone and Accessibility. Default ASR is Apple Speech on macOS 26 (Whisper / Parakeet are optional). Gemma 4 polish is optional (~2.7 GB) from Settings.

## 0.1.9

- **Spoken session context.** Press Shift during a take to store a short, temporary note about what you are working on. Nothing is pasted. Later dictations send it with polish so names and jargon resolve. Press Shift again to switch back to a normal paste. Edit or clear it from the menu or Settings. It is not saved across launches.
- Context takes use a hidden polish engine that distills what you said into a short topic. Your About you notes still help with names. With cloud polish, that phrase goes to the API too.
- The HUD shows an orange CONTEXT badge while that take is in progress, so it is obvious this will not paste.
- Polish no longer strips spoken millimetres (`5 mm`, `50 mm`) after LLM cleanup.

## 0.1.7

- **Cleanup is LLM-only.** The old heuristic rewrite is gone. Fillers (`um`, `uh`, `hmm`) still strip. False starts and “wait, no — actually” need Apple Intelligence (default on macOS 26), Gemma 4, or a cloud API key. On macOS 14–15, turn on Gemma or cloud polish for that cleanup.
- **Millimetres stay.** Spoken “5 mm” / “50 mm” is no longer treated as a filler pause.
- Cloud polish shows whether a key is saved, and On this Mac vs Cloud is a choice you can see at once.
- The menu bar shows the active polish model.
- Fix a dangling audio-buffer pointer on Bluetooth format changes.
