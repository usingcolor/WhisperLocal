<p align="center">
  <img src="assets/banner.png" alt="WhisperLocal — local-first dictation for Apple Silicon" width="100%">
</p>

# WhisperLocal

Local-first dictation for Apple Silicon Macs.

Hold a global hotkey, speak, release — cleaned text is inserted at the cursor in any app. Audio never leaves your Mac unless you opt in to cloud polish, which sends **transcript text only**.

Native Swift / AppKit. Default on-device ASR is Apple Speech (`SpeechTranscriber`, macOS 26); [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) and [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) are optional. Default on-device polish is Apple Intelligence (`SystemLanguageModel`); Gemma 4 E2B IT (MLX, text-only) is optional. No Ollama.

> Early preview (`0.1.0`). Built for daily use on one machine; expect sharp edges.

## Download

Apple Silicon only. Get the DMG from [Releases](https://github.com/usingcolor/WhisperLocal/releases/latest) — no Xcode or git clone required.

1. Open the disk image and drag **WhisperLocal** into **Applications**.
2. First launch: right-click the app → **Open**. The download is ad-hoc signed (not Apple-notarized), so Gatekeeper warns once.
3. Grant **Microphone** and **Accessibility**.

Speech models: Apple Speech uses a system model (may download once via macOS). Whisper / Parakeet / Gemma still download on first use if you pick them.

## Features

- Menu-bar agent (no Dock icon)
- Global hotkey — default **Globe / Fn**; hold-to-talk or tap-to-toggle
- **Esc** cancels an in-progress dictation
- On-device English ASR: Apple Speech by default (macOS 26); WhisperKit or Parakeet TDT 0.6B v2 optional
- Offline heuristic cleanup (optional), then Apple Intelligence polish by default, or Gemma 4 E2B IT
- Optional OpenAI or Anthropic polish (text only; keys in Keychain)
- Editable custom instructions and personal dictionary for polish
- Fail-open: if AI cleanup fails or times out, the previous stage is still pasted (heuristic if it ran, otherwise raw ASR)
- Insert via Accessibility, with clipboard ⌘V first in Electron / Chromium apps (Cursor, Chrome, Slack, VS Code, …)
- Dictation log (last 100 entries, text only — no audio)
- Floating recording HUD

## How it works

```
hold hotkey → record 16 kHz audio
           → Apple Speech (default; or WhisperKit / Parakeet)
           → heuristic polish  (optional; fillers, self-corrections, spoken punctuation, dictionary)
           → Apple Intelligence (default; or Gemma 4 E2B IT; skipped when cloud polish is on)
           → OpenAI / Anthropic                   (optional; replaces the on-device LLM)
           → insert at cursor
```

Questions in the transcript stay as dictated text. The polish step is not a chatbot.

Apple Intelligence polish needs **macOS 26+** with Apple Intelligence enabled. Gemma 4 E2B IT runs on any Apple Silicon Mac via MLX (first use downloads ~2.7 GB of text-only 4-bit weights — vision and audio towers are not loaded). On macOS 14–15 without Gemma loaded, cleanup is heuristic-only unless you add a cloud key.

## Requirements

To **run** the app:

- Apple Silicon Mac (M1 or later)
- macOS 14 or later
- Microphone and Accessibility permissions

To **build from source** you also need Xcode 16.4+ (mlx-swift 0.31.6 needs Swift 6.3 tools) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). A Release DMG:

```bash
bash scripts/make-dmg.sh
```

The app is **not sandboxed**. Global hotkeys, Accessibility insertion, and synthetic paste need that.

## Build from source

```bash
brew install xcodegen   # if needed

cd WhisperLocal
xcodegen generate
open WhisperLocal.xcodeproj
```

In Xcode, set your own **Development Team** (Signing & Capabilities), then Run. This repo does not include an Apple team ID.

CLI (arm64 only — FluidAudio uses `Float16`, which is unavailable on x86_64):

```bash
xcodegen generate
xcodebuild -scheme WhisperLocal -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  ARCHS=arm64 VALID_ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
  build
```

After changing `project.yml` or moving files, run `xcodegen generate` again.

First launch uses Apple Speech when macOS 26 is available (system English model). Whisper or Parakeet, if you pick them, download from Hugging Face into the engine cache — not this repo.

### Signing and Accessibility

Use **Apple Development** signing for local installs. Ad-hoc / hardened-runtime-only builds often show Accessibility as “Missing.”

If the insert step does nothing after a rebuild:

1. System Settings → Privacy & Security → Accessibility
2. Remove WhisperLocal, add it again
3. Quit and reopen the app (menu bar → **Quit WhisperLocal**)

The onboarding window shows the binary path that must be enabled.

## Usage

1. Grant **Microphone** and **Accessibility** when prompted.
2. Focus a text field.
3. Hold **Globe / Fn** (or tap twice in tap mode), speak, release.
4. Polished text appears at the cursor.

Hotkey alternatives in Settings: Right Option, Left Option, Right Command.

## Settings

| Setting | Default |
|---|---|
| Speech model | Apple Speech (macOS 26). Fallback Whisper `small.en`. Also `tiny.en`, `base.en`, Large v3 turbo, Parakeet TDT 0.6B v2 |
| Text cleanup | On |
| Heuristic cleanup | On (turn off to send raw ASR to the model) |
| On-device polish | Apple Intelligence (or Gemma 4 E2B IT; skipped automatically while cloud polish is on) |
| Cloud polish | Off (OpenAI / Anthropic; pick a model in Settings) |
| Custom instructions | Generic starter notes; edit or clear in Settings |
| Trailing space after paste | On |
| Dictionary | Editable list in Settings |

API keys are stored in the Keychain under `com.usingcolor.WhisperLocal`.

The dictation log is `~/Library/Application Support/WhisperLocal/dictation-log.json` (text only).

## Privacy

| Mode | What leaves the device |
|---|---|
| Default | Nothing. ASR, heuristic cleanup, and on-device polish (Apple Intelligence or Gemma) stay on this Mac. |
| Cloud polish enabled | Transcript **text** only, to OpenAI or Anthropic. |
| Audio | Never uploaded. |
| Log | Local JSON; no audio. |

## Project layout

```
WhisperLocal/
  App/            Info.plist, entitlements
  State/          DictationController, settings, log
  Services/       recorder, WhisperKit, hotkey, insert, polishers
  UI/             settings, HUD, onboarding, log
WhisperLocalTests/
project.yml       XcodeGen spec — regenerate after structural changes
```

Polish pipeline: `HeuristicPolisher` → one of `LocalLLMPolisher` (Foundation Models) or `GemmaMLXPolisher` (MLX) → optional `OpenAIPolisher` / `AnthropicPolisher`. Shared instructions live in `CleanupPrompt.swift`.

## Development

Polish unit tests (no microphone, no model download):

```bash
xcodegen generate
xcodebuild test -scheme PolishTests \
  -destination 'platform=macOS,arch=arm64'
```

## Related projects

If you need Windows, Linux, streaming, or a large model catalog, start here instead:

- [Handy](https://github.com/cjpais/Handy) — cross-platform offline STT
- [VoiceInk](https://github.com/Beingpax/VoiceInk) — Mac dictation with Modes and many enhancement backends
- [OpenWhispr](https://github.com/OpenWhispr/openwhispr) — cross-platform dictation + in-app llama.cpp cleanup

WhisperLocal is a small native Swift app: Apple Speech by default, or WhisperKit / Parakeet, plus on-device polish (Apple Intelligence or Gemma 4 via MLX), no sidecar LLM.

## Contributing

Issues and pull requests are welcome. Please keep changes focused.

Before opening a PR:

- Run `xcodegen generate` and the `PolishTests` scheme
- Do not commit API keys, signing identities, or personal dictionary contents

## License

Application source is [MIT](LICENSE). Speech-model weights have their own licenses — see [NOTICE](NOTICE). Parakeet TDT 0.6B v2 is NVIDIA CC-BY-4.0 (attribution, not copyleft). Gemma 4 is Apache 2.0 and is downloaded only if you select it. Do not call those files MIT.
