Apple Silicon only (M1 or later). Open the DMG and drag WhisperLocal into Applications.

<!-- The placeholder line below is replaced by .github/workflows/release.yml
     with the real signing state of this build. Do not hand-write it here. -->
{{SIGNING_SECTION}}

Then grant Microphone and Accessibility. Default ASR is Apple Speech on macOS 26 (Whisper / Parakeet are optional). Gemma 4 polish is optional (~2.7 GB) from Settings.

## 0.2.0

- **Long dictations no longer come out empty.** The clipboard was being restored on a fixed timer while a long paste was still being read, so the text was replaced mid-paste. Over 300 characters this failed most of the time. The app now waits for the paste to land, and if it still cannot confirm it, leaves the dictation on the clipboard and tells you to press ⌘V rather than discarding it.
- **A take now stops at ten minutes** instead of recording without limit. It transcribes what you said — it never throws the audio away — and the HUD counts down over the last minute.
- **Long takes are transcribed in pieces**, cut at natural pauses, so a failure costs one piece instead of everything you just said. Polish is split the same way, so a slow or failing cleanup no longer loses the whole take.
- **Cloud outages fall back to the on-device model** rather than pasting uncleaned text. Being offline is detected before the request, so there is no waiting for a timeout, and the HUD says which model actually ran.
- **Ignore playback** (Dictation settings, off by default) keeps music and video coming from this Mac out of your transcript. Playback dips while you talk. It has no effect on headphones.
- While headphones are playing, dictation uses the built-in mic so music stays at full quality. Bluetooth headsets cannot play high quality and record at once, and their mic is the worse input for speech anyway.
- **The dictation log has search and day grouping**, and its detail view leads with the transcript. Clearing it now asks first.
- The session context window shows whether a context is active, how old it is, and what will clear it.
- Settings lost roughly half its buttons. Permissions offers the fix on the row that needs it, API key pages are down to Save and Remove, and long explanations fold away behind More.
- The menu bar has real hierarchy — title, status, and grouped actions — instead of a flat list.
- Onboarding's **Quit & Reopen** now reopens, and **Start using WhisperLocal** closes the window.
- Text lands in the window you started dictating into, even if you switch Spaces mid-take.
- Updates refuse to install unless they are signed by the release team.
- Fixed a case where any multi-channel audio interface would record silence with no error.

## 0.1.9

- **Spoken session context.** Press Shift during a take to store a short, temporary note about what you are working on. Nothing is pasted. Later dictations send it with polish so names and jargon resolve. Press Shift again to switch back to a normal paste. Edit or clear it from the menu or Settings. It is not saved across launches.
- Context takes use a hidden polish engine that distills what you said into a short topic. Your About you notes still help with names. With cloud polish, that phrase goes to the API too.
- The HUD shows an orange CONTEXT badge while that take is in progress, so it is obvious this will not paste.
- Polish no longer strips spoken millimetres (`5 mm`, `50 mm`) after LLM cleanup.

## 0.1.8

- Release packaging only — no changes to the app itself.
- The release workflow can now sign with a Developer ID certificate, notarize with
  `notarytool`, and staple the ticket, when the Apple secrets are configured.
- The 0.1.8 DMG itself was still ad-hoc signed: the workflow fell back because those
  secrets were not set, so that download is blocked by Gatekeeper on first launch. Its
  release notes explain how to open it.

## 0.1.7

- **Cleanup is LLM-only.** The old heuristic rewrite is gone. Fillers (`um`, `uh`, `hmm`) still strip. False starts and “wait, no — actually” need Apple Intelligence (default on macOS 26), Gemma 4, or a cloud API key. On macOS 14–15, turn on Gemma or cloud polish for that cleanup.
- **Millimetres stay.** Spoken “5 mm” / “50 mm” is no longer treated as a filler pause.
- Cloud polish shows whether a key is saved, and On this Mac vs Cloud is a choice you can see at once.
- The menu bar shows the active polish model.
- Fix a dangling audio-buffer pointer on Bluetooth format changes.
