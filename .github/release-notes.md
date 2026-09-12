Apple Silicon only (M1 or later). Open the DMG and drag WhisperLocal into Applications.

<!-- The placeholder line below is replaced by .github/workflows/release.yml
     with the real signing state of this build. Do not hand-write it here. -->
{{SIGNING_SECTION}}

Then grant Microphone and Accessibility. Transcription runs on Apple Speech by default on macOS 26 (Whisper / Parakeet are optional). Gemma 4 polish is optional (~2.7 GB) from Settings.

## 0.2.1

- **Music and video no longer jump or dip when a take starts.** Opening the microphone on AirPods pulls the headset out of high-quality playback into its call profile, which restarts whatever is playing on a narrowband link and swaps in that profile's own volume. Dictation now records from the built-in or a wired microphone while a Bluetooth headset is playing, and opens that microphone directly so the headset is never touched on the way past.
- **Choose which microphone dictation uses** — from the recording HUD, the menu bar, or Settings. Picking one mid-take switches it without ending the take: a short gap, then the rest of the sentence on the new microphone, all in one transcript. Left alone, takes follow System Settings exactly as before.
- **Claude Sonnet 5 and Opus 5 work again.** Both rejected every request with a 400, so cleanup failed on two of the three models the picker recommends. They are also told not to think, which was spending the output budget before the cleaned text: a long take could come back cut short, or pasted with no cleanup at all.
- **Dictation lands in ChatGPT again.** Its bundle identifier changed, which quietly dropped it off the list of apps that need a clipboard paste — takes reported success and inserted nothing. Apps are now recognised by name as well, and a write that cannot be confirmed goes to the clipboard with the HUD saying so, rather than being reported as done.
- **Text no longer arrives twice in Safari and Mail.** Their accessibility tree updates after the edit, so the check for "did it land" ran too early, decided it had failed, and pasted a second copy.
- **Open WhisperLocal at login**, from Settings › General. The toggle follows System Settings › Login Items rather than remembering its own answer, and re-points itself if you move the app. It refuses on a copy running from a disk image, where a login item would point at nothing after a restart.
- **The recording HUD is a row of Liquid Glass capsules** rather than one frosted slab, and it holds still: the status capsule changes width with every phase, and the HUD used to slide sideways each time. It now opens in the same place on every take. Hovering it keeps it up, which is how the microphone list is reached after a take has finished.
- **Settings has a General page.** Opening at login and the dictation log live there now instead of halfway down Dictation, and Dictation is grouped into Hotkey, Microphone, Speech model and Inserted text.
- The OpenAI picker now starts on GPT-5.6 Luna, chosen by measuring every engine against the same transcripts. Apple Intelligence is still the default and still needs no key. The comparison is in the README.
- Long Japanese and Chinese takes are split and rejoined correctly. They put no spaces between sentences, so pieces were cut in the middle of one and put back together with spaces that do not belong.
- Quitting by dragging the menu bar item out of the menu bar works again, as it did in 0.2.0.

## 0.2.0

- **Long dictations no longer come out empty.** The clipboard was being restored on a fixed timer while a long paste was still being read, so the text was replaced mid-paste. Over 300 characters this failed most of the time. The app now waits for the paste to land, and if it still cannot confirm it, leaves the dictation on the clipboard and tells you to press ⌘V rather than discarding it.
- **Dictate for as long as you like.** Long takes are now transcribed while you are still speaking, so letting go is quick however long you talked, and memory stays flat instead of growing with the recording.
- **Esc, or the ✕ on the recording HUD, abandons a dictation** that is still being transcribed or polished. Previously there was no way out once you let go.
- Long takes are cut at natural pauses, so a failure costs one piece instead of everything you just said. Polish is split the same way, so a slow or failing cleanup no longer loses the whole take.
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
- Quitting now asks before discarding a dictation that is still recording or being transcribed, instead of throwing it away silently.
- The menu bar explains when a focused password field is blocking the hotkey. macOS withholds key events while one is focused, which used to leave dictation dead with nothing to explain it.
- Unplugging a microphone mid-take ends the take with what it captured, rather than carrying on against a dead input and recording nothing.
- Sleeping mid-take finishes the take on wake instead of truncating it without a word.
- A full disk says so, instead of surfacing an `OSStatus` code.
- The recording HUD follows display changes rather than staying on a screen you unplugged, and on macOS 26 it uses Liquid Glass.
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
