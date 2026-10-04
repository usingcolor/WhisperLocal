Apple Silicon only (M1 or later). Open the DMG and drag WhisperLocal into Applications.

<!-- The placeholder line below is replaced by .github/workflows/release.yml
     with the real signing state of this build. Do not hand-write it here. -->
{{SIGNING_SECTION}}

Then grant Microphone and Accessibility. Transcription runs on Apple Speech by default on macOS 26 (Whisper / Parakeet are optional). Gemma 4 polish is optional (~2.7 GB) from Settings.

## 0.2.5

- **Context follows your dictation.** Apple Intelligence or your selected cloud cleanup provider can keep up to three short topics after each paste, helping later dictations resolve names and terminology. Automatic topics fade after 15 unused takes or 45 minutes. Learning can be switched off in Context or Settings → Polish, and context clears when the app quits.
- **Read and edit context in one window.** Automatic topics, Shift dictation and typed notes share a readable list. Open **Edit Context…** from the menu bar or press **Control + Shift + K** between takes. Type a correction and save with **Command + Return**. Corrected topics and typed notes stay until removed or the app quits; learning cannot rewrite them. The recording toolbar shows an active-context summary and a button to open the window.
- **Context and the dictation log match Settings.** Both use native grouped sections and window controls. Context keeps its editable inline topics; the log uses readable transcript text and labeled details.
- **Choose toolbar transparency.** Settings → General → Recording toolbar has a Background opacity slider, starting at **90%**. Text and controls stay visible as the background fades. Reduce Transparency and Increase Contrast keep full-strength material.
- **Dictation and cleanup recover more reliably.** Holding the hotkey no longer ends a take early when a modifier check disagrees. Streaming transcription handles cancellation and queued chunks more carefully, on-device cleanup has a time limit, and the dictation log preserves a recoverable copy if its file is damaged.
- **OpenAI cleanup starts with GPT-6 Luna.** Existing saved model choices are kept. Cloud cleanup also handles unsupported model parameters more reliably.
- A refreshed app icon.

Apple Intelligence learns names containing capitals or digits; type names in scripts such as Korean, Japanese or Chinese into Context. Gemma can use notes but does not learn automatic topics. Cloud learning makes a second request to your selected cleanup provider with the take, context and app name. Your audio stays on your Mac.

<!-- 0.2.5 preparation — 2026-10-02
Publication is ON HOLD until the maintainer explicitly approves. Do not push a public
release tag or publish a draft yet. The release workflow creates drafts only.

Scope: automatic context, the unified Context editor, 90% HUD background default,
and the dictation/cleanup/log reliability fixes. Volunteer data sharing, related
takes, term suggestions and window-title capture remain Dev-only.

Verification and local candidate:
- Final 373-test suite passed after the UI revision, none skipped, with an isolated synthetic localhost sharing
  server. Includes consent withdrawal, duplicate submissions, export and deletion.
- Release app 0.2.5 (24), public bundle ID, built and Developer ID signed with
  hardened runtime, timestamp and the declared entitlements; signatures verified.
- dist/WhisperLocal-0.2.5-arm64.dmg passed hdiutil verification. Not notarized yet.
- Release metadata and workflow shell guards passed; both benchmark tools built.
- Context and log native UI checked in light and dark appearances using synthetic
  data. Keyboard save/discard, focused-note removal, empty state, log search and
  clear confirmation passed. Fixed stale array bindings that crashed discard.
  The eight context draft tests passed again; Dev 0.2.5 (24) is installed locally.
- Demo fixture validated. Apple Intelligence and GPT-6 Luna each retained Joaquin
  through ten intervening takes, but both left the walking probe unchanged.
  No controls harmed in the plain or separate arms of these synthetic replays.
Before public distribution: review the candidate, verify dictation and Context
on the Mac, notarize and staple the final DMG, then obtain publication approval.
Hold the new demo out of the public README and release announcement until a
revised example passes the app pipeline. The files remain for revision. The video
is an illustration, not a screen recording; do not imply every engine fixes every
name. Release source is frozen on codex/release-0.2.5 for draft review. Public
tagging and publication remain on hold until explicitly approved.

Deferred volunteer sharing — do not enable in the public 0.2.5 bundle:
P1: bind credentials, enrollment and consent to a canonical server origin. The
editable server address currently reuses the existing token/consent at any new
HTTPS address. Review redirects so text cannot follow a redirect to another
origin. Re-enroll explicitly if the destination changes.
P1: make consent version changes require renewed opt-in; the current store only
checks whether improve is present. Serialize or cancel uploads when consent,
redaction, exclusion settings or deletion change during an in-flight request.
The UI currently disables Stop Sharing while busy, despite promising immediate
withdrawal. Prove this with delayed-server tests and offline/restart tests.
P1: verify the actual volunteer service's access control, export, erasure and
retention, including any backups and training consumers. The repository contains
only a localhost test server; it has no retention purge and its dashboard has no
authentication. A client test cannot certify the deployed service.
P2: measure redaction in the supported languages and make its limitations clear;
Korean names currently remain. Make manual review the default before considering
automatic sharing beyond the private trial. Avoid absolute removal promises.
P2: validate queued-file recovery, endpoint migration and enrollment interrupted
by Keychain failures. Track acceptance receipts and consent applied to each take.
Keep training consent separate and enforce it in downstream consumers.
-->

## 0.2.4

- **The recording HUD is now a recording toolbar, and it holds still.** It is laid out like a macOS toolbar: status on the left, the language and microphone sharing one capsule, and ✕ on its own. The status capsule keeps one width and one height for the whole take instead of changing with every step. Every message the app writes fits in it, and a system error too long for it is cut short, with the whole line shown when you hover. The microphone shows as an icon: hover it to see which one is in use, and click it to choose another.
- **Put the toolbar where you want it.** Settings › General › Recording toolbar offers bottom centre (where it has always been), top centre, bottom left and bottom right. Turn on “Let me drag it” to put it anywhere, and right-click the toolbar to reset it. Dragging is off by default, so nothing moves unless you ask.
- **✕ cancels while you are still speaking**, the same as Esc. Before, it only appeared once you had let go.
- **Claude and other Chromium and Electron apps — Slack, VS Code, Cursor, Discord, Chrome — no longer tell you to press ⌘V after a paste that worked.** WhisperLocal could not see inside these apps to confirm the text had landed, so it asked for ⌘V every time, and doing so pasted the text twice. It now asks each app to expose its text as a take starts.
- **“Ignore playback” is gone.** With it on, a take took more than three seconds to start, and in testing four starts in seven never reached the microphone at all; without it the microphone opens in under a tenth of a second. It was off by default. If you had turned it on, sound from your speakers can reach the transcript again — headphones avoid that.
- **Dictated text no longer ends with a space.** “Insert trailing space” was on by default and has been removed, so text ends where the sentence ends. Two takes in a row now run together; type the space between them yourself.
- **Settings stays in front when you switch desktops and come back**, instead of dropping behind another app on that desktop.
- **The dictation log records each take’s language and microphone**, including a switch mid-take (“MacBook Air Microphone → AirPods Pro”), in the log window and its exports. Its switch and the button that opens it moved to Settings › Dictation › History, next to the last dictation.
- **The SHA-256 is printed at the bottom of these notes** instead of in a separate `SHA256SUMS` file, and from this version on the in-app updater checks downloads against it.

## 0.2.3

- **Dictate in another language.** Set a dictation language in Settings › Language, or let it follow your keyboard: switch to a Korean or Japanese input source and the next take is transcribed and cleaned in that language, with the language shown on the recording HUD before you speak. Switching input source while the key is still held changes the take you are in. A language is only used if it can be served right now — the first take in a new language may download an on-device model, and until that finishes the take falls back to your default language rather than waiting. This ran behind a Dev-only flag while it was unproven; it is on for everyone now.
- **The app now says when it is running from a temporary copy.** macOS runs an app still flagged as downloaded from a randomised location that disappears on quit, so "Open at login" cannot work and permissions do not stay granted — and nothing told you. The menu bar now shows a warning, and the welcome window explains it with a Show in Finder button: drag the app out of your Applications folder and back in, which clears the flag, then reopen it. No Terminal.
- **New installs are asked about opening at login** in the welcome window, instead of leaving the switch to be found three pages into Settings.

## 0.2.2

- **An update installed from inside the app no longer breaks "Open at login".** The updater flagged what it downloaded as quarantined and carried that flag into the installed app, and macOS runs a flagged app from a temporary randomised location rather than from where it sits — so the login item was refused, correctly, and the app moved on every launch. The flag is now cleared once the download's signature and publisher have been verified. If you are already in this state, drag WhisperLocal out of your Applications folder and back in, then reopen it; the refusal message now says so instead of telling you to move an app that is already there.
- **The menu bar item stays open in a full-screen Space.** It was a panel pinned to the icon rather than a menu, and the system only holds the menu bar down for a real menu, so it vanished the moment the pointer moved away. It is now a native menu: system highlighting, arrow keys, key equivalents, and a proper submenu for the microphone instead of one row per device.
- The transcription model is now called that — in Settings, in the menu bar, and here. It had been "Speech model", "ASR", and "speech-to-text" in three different places for one thing.
- "Reload Speech Model" is gone from the menu bar unless it can help. A model that failed to load does not retry itself, so the repair still exists — it appears as "Retry loading …" only when the model is not ready, and Settings has the same button beside the status line that explains the failure.

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
