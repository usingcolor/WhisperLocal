# Polish benchmark

Which model, and which prompt, cleans a dictation best — measured on the app's own
polishing code rather than a copy of it, so it measures what ships.

`polish-bench` is a command-line target in the same Xcode project as the app. It
builds the real `PolishPipeline`, with the real prompts, the real filler filter and
the real splitting, and runs every test case through each engine.

```bash
CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/polish-bench.sh run \
  --engines all --pilot --keychain
```

The script builds first, then runs. `CODESIGN_IDENTITY` is worth setting: the tool
can read the API keys WhisperLocal saved, and macOS ties that permission to the
binary's signature, so an unsigned rebuild asks again every time.

## Keys

`OPENAI_API_KEY` and `ANTHROPIC_API_KEY` from the environment, or `--keychain` to
read the keys the app saved (macOS asks the person at the keyboard to allow it).
Keys are never written to disk by the benchmark and never appear in its output.

## Commands

| Command | What it does |
| --- | --- |
| `run` | Polish every case with every engine, score the code checks, print the table |
| `judge` | Compare each engine head to head with the anchor, both orders, by judge models |
| `report` | Rebuild the summary from saved outputs and verdicts (free; nothing is re-run) |
| `validate` | Score every answer key against its own case's rules — run this after editing cases |
| `prompt` | Print exactly what one engine is sent for one case |
| `probe` | Send one request and print the provider's raw response: stop reason, token counts |
| `engines` | List engine names |

Useful flags: `--pilot` (ten cases), `--half tune|test`, `--category korean`,
`--only <ids>`, `--repeats N`, `--parallel N`, `--fresh` (ignore the cache),
`--name <run>`.

Every output is cached under `Benchmarks/results/cache/`, keyed by a hash of the
exact prompt the engine was sent. Change the app's prompts and the cache misses;
re-score or add a judge and nothing is re-run. Failed takes are never cached.

## Engines

`raw` (no cleanup) and `fillers` (the app with no LLM selected) are the baselines:
an LLM that cannot beat filler-stripping is not worth the wait. `apple` is Apple
Intelligence, `gemma` is Gemma 4 E2B, and every other name is a cloud model id
straight from the app's own catalog.

`--engines oss` adds four open-weight models the app does not ship, to answer
whether the on-device slot is worth changing: `qwen3-4b`
(`mlx-community/Qwen3-4B-Instruct-2507-4bit`, ~2.3 GB), `ministral-3b`
(`mlx-community/Ministral-3-3B-Instruct-2512-4bit`, ~2.8 GB), `granite-4-micro`
(`mlx-community/granite-4.0-h-micro-4bit`, ~1.8 GB) and `llama-3.2-3b`
(`mlx-community/Llama-3.2-3B-Instruct-4bit`, ~1.8 GB). The first three are
Apache-2.0; Llama 3.2 is ungated but under Meta's community licence, so it is here
as a comparison point rather than as something the app could ship without a licence
review. All are 4-bit MLX conversions, and each runs through the app's own
`GemmaMLXPolisher` with only the weights swapped — same prompt, same token budget,
same greedy decode — so their wait times can be read against `gemma` directly.
They are not in `all`: each is a download of a few GB, so ask for them by name or
as `oss`. A thinking model cannot be added here without more work; one that opens
a `<think>` block will trip the output cap and the take will read as a failure.

## Cases

`cases/transcripts.json` — 125 hand-written cases, public and committed so results
can be reproduced. Each one carries what speech recognition produced, one
acceptable clean version, and rules a script can check.

```json
{
  "id": "falsestart-02",
  "category": "fillers",
  "raw": "Let's meet at three, scratch that, let's meet at four.",
  "reference": "Let's meet at four.",
  "app": "Slack — chat app",
  "language": "ko",
  "dictionary": ["WhisperLocal"],
  "task": "sessionContext",
  "checks": {
    "mustContain": ["four"],
    "mustNotContain": ["scratch that", "three"],
    "verbatim": false,
    "minRatio": 0.6,
    "maxRatio": 1.5
  }
}
```

`app` is the target-app line exactly as the app sends it. `language` is absent for
English. `dictionary` adds to the app's default dictionary. `task` is `dictation`
unless the case is a Shift-context take. Ratios are output length against the
answer key, in non-space characters.

Cases are split into a tuning half and a reported half by a hash of the id, so
adding cases never moves an existing one between halves.

## Scoring

**Hard failures**, counted by code, zero tolerance: answered instead of cleaned,
changed language, dropped content, added a preamble, misspelled a dictionary word,
plus each case's own rules.

**Edit rate**: token-level distance to the answer key, by character for Korean,
where spacing legitimately varies. Reported with a bootstrap range, because at this
size a small gap is noise.

**Judges**: two models from different providers compare each engine head to head
with an anchor engine, every pair shown in both orders so position bias cancels.
Judge agreement is reported; when the judges disagree with each other, no
leaderboard built on them should be trusted.

**Cost of use**: wall time per take, tokens in and out, cache share, and dollars
per 1,000 takes from `prices.json` — list prices with the date they were checked.

## Not here yet

The audio track: real recordings through the speech models, scored against a
ground-truth transcript, with the same clip polished from a perfect transcript for
comparison. Datasets would live in `Benchmarks/data/`, which is git-ignored.

`Benchmarks/results/` is git-ignored too: outputs cost money to make and can
contain whatever the cases contain.
