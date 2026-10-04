# Context benchmark

Measures automatic context — polish keeping a few topics of what you are working
on — on the three questions that decide whether it ships: does context help
polish recover names at all, does the updater keep topics well enough to deliver
that, and what does it cost in wait and in harm to takes it should leave alone.

It runs the app's own polish pipeline, prompt and `AutoContext` rules, the same
way the polish benchmark does. Results go under `Benchmarks/results/context/`,
which git ignores.

```
scripts/context-bench.sh validate                 # free: checks the cases against themselves
scripts/context-bench.sh seed-check --keychain    # does a fixed seed make the model repeat itself?
scripts/context-bench.sh sessions --keychain      # scripted sessions through every arm
scripts/context-bench.sh sessions --polish apple  # all on this Mac: Apple Intelligence polishes and keeps names
scripts/context-bench.sh sessions --updater apple --keychain  # cloud polish, names kept on this Mac
scripts/context-bench.sh real-log --keychain      # your own takes, for the blind comparison page
scripts/context-bench.sh blind-score --name <run> --results <saved JSON>
```

The key comes from `OPENAI_API_KEY`, or with `--keychain` from the one WhisperLocal
saved; macOS asks whoever is at the Mac to allow that. A run with nothing in the
cloud needs no key. The OpenAI model defaults to the Dev app's; `--sessions s01,s05`
runs only those, for a quick look.

## Scripted sessions

`cases/sessions.json` — ten sessions of twelve takes, each interleaving two threads
the way work actually goes: a paper and a family lunch in Korean, a pipeline
migration and a hiring loop. People, projects and places are invented. Every take
has an answer key and a role:

- **setup** says a name correctly, the first time its thread comes up.
- **probe** mishears that name later, with no other clue. A *near* probe's name was
  said in the last eight takes, which polish already sees as examples; a *far*
  probe's was not, so only context can recover it.
- **distractor** is more of a thread, without the name.
- **control** must come back unchanged in meaning and language, context or not.
- **smalltalk** should not change the topics.

`validate` fails if any answer key fails its own checks, or any probe's raw text
already passes — a probe the raw text passes tests nothing.

## Release demo replay

`cases/demo.json` keeps the illustrated 0.2.5 Joaquin → walking example separate
from the scored sessions above: one setup, ten intervening takes in other apps,
then a name-recovery probe. It uses synthetic text, with no personal dictionary
seed. This tests the context and cleanup pipeline, not the microphone or ASR.

```bash
scripts/context-bench.sh validate --cases Benchmarks/ContextBench/cases/demo.json
scripts/context-bench.sh sessions --cases Benchmarks/ContextBench/cases/demo.json \
  --polish apple --arms plain,separate --samples 1 --parallel 1 --name demo-0.2.5
```

The Apple run stays on this Mac. Inspect the saved steps and report before claiming
the particular example works on an engine; the animation alone is not evidence.

Release check, 2 October 2026, one sample per take: Apple Intelligence and GPT-6
Luna each retained Joaquin through the ten intervening takes, but both left the
final “walking” unchanged, with or without automatic context. No controls were
harmed. The 0.2.5 README therefore holds the new demo until a revised example is
reproduced; this fixture remains as a regression case. These runs do not change
the historical ten-session scores below.

## Arms

| Arm | What polish sees | What it answers |
|---|---|---|
| `plain` | recent takes as examples, as the app does without auto context | — |
| `oracle` | the correct topics, as a session context | the most context can do for polish |
| `separate` | the kept topics as a session context; then the app's own update request, as Dev makes it after the paste, reports the change | the Dev design |

Both show topics as the app does for that polish engine. Since 30 September
2026 cloud polish gets a list, newest first, each topic with the last two apps it
came up in and how long ago — for the oracle, the apps and minutes of its
thread's takes so far — and Apple Intelligence polish gets the topics' words on
one line. Each take's examples are that run's own earlier outputs, and the
topics carry forward take by take. Two arms that send an identical prompt share one cached
answer, so they differ only where their inputs do.

The separate arm's update is the app's own for the engine that makes it: a
second request to the cloud model, or Apple Intelligence listing names (below).

A fourth arm, `single`, asked polish for the change in the same reply. It was
retired on 28 September 2026: it kept 38% of what correct topics gain against
68% for a separate request, added 0.7 s to every paste, and GPT-6 Luna left the
line out of 29% of replies. Runs made before then still read with `report`.

## Apple Intelligence

`--polish apple` polishes with Apple Intelligence, as the app does on this Mac,
and `--updater apple` has it keep the topics with a prompt of its own: it lists
the names in the take, in a fixed shape, and the app decides where they go
(`AutoContext.change(names:in:topics:)`). A name must appear in the take as given,
carry a capital or a digit, and not be a weekday, a month, or the whole take. It
is greedy, so runs default to one sample and what it said is cached per take; the
app's rule runs every time, so changing it costs nothing to see.

It is asked for so little because three richer prompts failed on these sessions.
Choosing use, refine, add or skip, it answered "use 1" to nearly every take, with
nothing listed yet. Shown the topics, it copied the first into its answer. Asked
what named work a take was part of, it named the task in front of it — "table",
"invoice", "diff" — and pushed the real topics out.

28 September 2026, macOS 27.2, far probes fixed:

| Polish | Topics | Far probes | vs no topics |
|---|---|---|---|
| Apple Intelligence | none | 5% | — |
| Apple Intelligence | correct, as scripted phrases | 40% | +35 pts [+20, +45] |
| Apple Intelligence | names kept by Apple Intelligence | 50% | +45 pts [+30, +60] |
| GPT-6 Luna | none | 38% | — |
| GPT-6 Luna | correct, as scripted phrases | 95% | +57 pts [+40, +73] |
| GPT-6 Luna | kept by GPT-6 Luna in a second request | 80% | +42 pts [+25, +57] |
| GPT-6 Luna | names kept by Apple Intelligence | 92% | +53 pts [+37, +70] |

30 September 2026, topics as a list with where and when, far probes fixed:

| Polish | Topics | One line (28 Sep) | List with apps and time |
|---|---|---|---|
| GPT-6 Luna | correct, as scripted phrases | 95% | 100% |
| GPT-6 Luna | kept by GPT-6 Luna in a second request | 80% | 85% |
| GPT-6 Luna | names kept by Apple Intelligence | 92% | 95% |
| Apple Intelligence | names kept by Apple Intelligence | 50% | 40% |

No control harmed in any of them. The cloud updater also sees where and when;
told in its prompt that a take in a topic's app soon after is often part of it,
it answered "none" to 55 of 120 distractor takes instead of 38 and let threads
fade when work moved between apps (78%, 191 of 327 thread-takes covered), so
the prompt now only shows them (85%, 230 covered, against 222 before). On this
Mac the ~3B model did worse with the list — 8 of 20 far probes against 10, and
once "Professor Nnamdi", the first name listed, for "Adebayo-Lindqvist" — so
Apple Intelligence polish keeps the one line. All within the intervals; none of
it is a clear win on its own, but the cloud gains agree in direction.

No arm harmed a control. Apple Intelligence keeps the names in 0.65–0.8 s on this
Mac, against 1.3 s for the second cloud request. Paired by session, names kept on
this Mac fixed 12 points more far probes than the cloud's topics (95% [−2, +23]):
better in five sessions, the same in four, and worse in one, which lost a Korean
name the capital rule cannot keep. Apple Intelligence polish sees three recent takes
where the cloud sees eight.

## Scores

All by script, no judge:

- **probe fixed** — every required spelling present exactly, no misheard form left;
- **control harmed** — language changed, a context line leaked into the text, or a
  name or number invented that neither the raw take nor the answer key has
  ("Table 2" for "the table", a topic pasted into a take about something else);
- **edit rate** against the answer key, ignoring case and punctuation;
- **wait** per take, and the updater's own time for the separate arm;
- **keeping topics** — a thread represented after its takes, the name captured
  before a far probe, topics merged across threads, topics over eight words —
  as kept, and as the model wrote them before the app cut them — changes made
  on small talk, no answer at all.

Ranges are 95% bootstrap intervals over sessions. GPT-6 Luna does not repeat
itself even with a fixed seed (4 of 6 takes did, against 3 of 6 without), so
runs default to three samples per take and report rates across them.

The report ends with the rules decided before the first run: correct topics must
fix clearly more far probes than plain; an auto-context arm must deliver at least
half of that gain, harm no more controls than plain, and — for a design that sits
on the paste, as the single call did — add no more than 0.2 s to the median wait.

## Your own takes, compared blind

`real-log` polishes the Dev dictation log three ways — plain, plain again, and
with auto context carried forward — and writes `blind.html` beside the results.
Open it in a browser: each pair is one take cleaned two ways, shuffled and
unlabelled, with the differing words highlighted. Keys 1 and 2 pick a side, 3 says
they are the same, Backspace goes back. Choices stay in that browser; the page
shows the tally at the end and can download it for `blind-score`.

Noise pairs — plain against itself — are mixed in. How often one of those is
preferred is how much of a preference chance alone produces, which is the line a
context pair's result has to clear.
