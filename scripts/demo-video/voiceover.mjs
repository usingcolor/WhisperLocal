// Voice-over for the 0.2.5 demo: Cartesia speaks each line, ffmpeg lays the
// lines on the video at their times. Two voices — a narrator, and someone
// dictating the two takes, so the viewer hears "Joaquin" said right while the
// screen shows what the recogniser made of it.
//
//   node scripts/demo-video/voiceover.mjs voices   # English voices to choose from
//   node scripts/demo-video/voiceover.mjs build    # speak, mix, and put it on the video
//
// The key comes from CARTESIA_API_KEY, else the Keychain item "cartesia-api-key".
// Lines already spoken are cached by everything that shapes them, so changing
// one line re-speaks only that one.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const out = join(root, "dist/demo/vo");
const API = "https://api.cartesia.ai";
const VERSION = "2026-08-14";
const MODEL = "sonic-3.6";
const DURATION = 36.2;

// Chosen from `voices`. Narrator: calm and clear. Speaker: casual, a person
// talking to their Mac.
const VOICES = {
  narrator: process.env.VO_NARRATOR ?? "5568a7df-e5ab-4442-9fae-2e9ba1b15ad8", // Quentin, "Refined Narrator"
  speaker: process.env.VO_SPEAKER ?? "e8e5fffb-252c-436d-b842-8879b84445b6", // Cathy, "Coworker"
};

// Joaquin, as it is said: wah-KEEN. Spelled out, a model may read it the way it
// is written, and the whole video rests on hearing it said right.
const JOAQUIN = "<<w|ɑ|k|iː|n>>";

// `at` is when the line starts in the video, in seconds. The two takes are
// timed so the speaking ends just before the key is let go.
const LINES = [
  { id: "01-say", voice: "narrator", at: 0.25, text: `You say ${JOAQUIN}.` },
  { id: "02-hear", voice: "narrator", at: 1.75, text: "It hears… walking." },
  { id: "03-promise", voice: "narrator", at: 5.9, text: "WhisperLocal now remembers what you're working on." },
  { id: "04-take-a", voice: "speaker", at: 10.1, text: `Um, can we set up an interview with ${JOAQUIN} for Thursday?`, speed: 1.05 },
  { id: "05-track", voice: "narrator", at: 15.6, text: "As you talk, it keeps track." },
  { id: "06-later", voice: "narrator", at: 17.9, text: "Ten takes later, in other apps, it still remembers." },
  { id: "07-take-b", voice: "speaker", at: 21.8, text: `Um, I think ${JOAQUIN} would be great for the team.`, speed: 1.05 },
  { id: "08-right", voice: "narrator", at: 26.4, text: "Heard wrong. Written right." },
  { id: "09-private", voice: "narrator", at: 28.9, text: "And your voice never leaves your Mac." },
  { id: "10-end", voice: "narrator", at: 32.3, text: "WhisperLocal. Free and open source." },
];

function apiKey() {
  const fromEnv = process.env.CARTESIA_API_KEY?.trim();
  if (fromEnv) return fromEnv;
  try {
    return execFileSync("security", ["find-generic-password", "-s", "cartesia-api-key", "-w"], { encoding: "utf8" }).trim();
  } catch {
    throw new Error("no Cartesia key: set CARTESIA_API_KEY, or add the Keychain item \"cartesia-api-key\"");
  }
}

const headers = () => ({ Authorization: `Bearer ${apiKey()}`, "Cartesia-Version": VERSION, "Content-Type": "application/json" });

async function listVoices() {
  let after = null;
  const voices = [];
  do {
    const query = new URLSearchParams({ language: "en", limit: "100" });
    if (after) query.set("starting_after", after);
    const response = await fetch(`${API}/voices?${query}`, { headers: headers() });
    if (!response.ok) throw new Error(`voices: HTTP ${response.status} ${await response.text()}`);
    const page = await response.json();
    voices.push(...page.data);
    after = page.has_more ? page.next_page : null;
  } while (after);
  for (const voice of voices) {
    console.log([voice.id, voice.name, voice.gender ?? "", voice.tagline ?? "", (voice.description ?? "").slice(0, 90)].join(" | "));
  }
  console.log(`${voices.length} voices`);
}

function seconds(file) {
  return Number(execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file], { encoding: "utf8" }).trim());
}

async function speak(line) {
  const voice = VOICES[line.voice];
  if (!voice) throw new Error(`no ${line.voice} voice: set VO_${line.voice.toUpperCase()} to a voice id from \`voices\``);
  const body = {
    model_id: MODEL,
    transcript: line.text,
    voice: { id: voice },
    output_format: { container: "wav", encoding: "pcm_s16le", sample_rate: 48000 },
    language: "en",
    ...(line.speed ? { generation_config: { speed: line.speed } } : {}),
  };
  const hash = createHash("sha256").update(JSON.stringify(body)).digest("hex").slice(0, 16);
  const file = join(out, "lines", `${line.id}-${hash}.wav`);
  if (!existsSync(file)) {
    const response = await fetch(`${API}/tts/bytes`, { method: "POST", headers: headers(), body: JSON.stringify(body) });
    if (!response.ok) throw new Error(`${line.id}: HTTP ${response.status} ${await response.text()}`);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, Buffer.from(await response.arrayBuffer()));
  }
  return { ...line, file, length: seconds(file) };
}

async function build() {
  mkdirSync(out, { recursive: true });
  const spoken = [];
  for (const line of LINES) spoken.push(await speak(line));

  // Where each line lands, and whether it runs into the next.
  spoken.forEach((line, i) => {
    const end = line.at + line.length;
    const next = spoken[i + 1];
    const clash = next && end > next.at - 0.1 ? `  ← runs ${(end - next.at + 0.1).toFixed(2)} s into ${next.id}` : "";
    console.log(`${line.id.padEnd(11)} ${line.at.toFixed(2)}–${end.toFixed(2)} s  (${line.length.toFixed(2)} s)${clash}`);
  });
  writeFileSync(join(out, "timing.json"), JSON.stringify(spoken.map(({ id, at, length }) => ({ id, at, length })), null, 2));

  // One track: every line at its time, levelled for the web (-16 LUFS).
  const inputs = spoken.flatMap((line) => ["-i", line.file]);
  const delays = spoken.map((line, i) => `[${i}:a]aresample=48000,adelay=${Math.round(line.at * 1000)}:all=1[a${i}]`);
  const mix = `${spoken.map((_, i) => `[a${i}]`).join("")}amix=inputs=${spoken.length}:normalize=0,apad,atrim=0:${DURATION},loudnorm=I=-16:TP=-1.5:LRA=11[vo]`;
  const track = join(out, "voiceover.wav");
  run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...inputs, "-filter_complex", [...delays, mix].join(";"), "-map", "[vo]", "-ar", "48000", track]);

  // Onto the master (picture untouched) and a copy small enough to share.
  const master = join(root, "dist/demo/whisperlocal-0.2.5-demo.mp4");
  const withVoice = join(root, "dist/demo/whisperlocal-0.2.5-demo-vo.mp4");
  const share = join(root, "dist/demo/whisperlocal-0.2.5-demo-vo-share.mp4");
  run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", master, "-i", track, "-map", "0:v", "-map", "1:a",
    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", withVoice]);
  run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", withVoice, "-c:v", "libx264", "-profile:v", "high",
    "-pix_fmt", "yuv420p", "-crf", "23", "-preset", "slow", "-c:a", "copy", "-movflags", "+faststart", share]);
  console.log(`wrote ${withVoice}\nwrote ${share}`);
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: ["ignore", "inherit", "inherit"] });
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}`);
}

const command = process.argv[2];
if (command === "voices") await listVoices();
else if (command === "build") await build();
else console.log("usage: voiceover.mjs voices | build");
