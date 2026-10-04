// Renders index.html to an MP4, frame by frame, with the Chrome and ffmpeg this
// Mac already has — no packages. Each frame calls window.renderAt(t) and takes
// a screenshot, so the video is exact at any frame rate however slow the page.
//
//   node scripts/demo-video/render.mjs                        # 60 fps MP4
//   node scripts/demo-video/render.mjs --stills 1,8.5,18.2    # PNG stills to look at
//   node scripts/demo-video/render.mjs --fps 30 --out demo.mp4
//   node scripts/demo-video/render.mjs --gif                  # assets/demo.gif for the README
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith("--")) pairs.push([arg.slice(2), all[i + 1]?.startsWith("--") ? true : all[i + 1] ?? true]);
    return pairs;
  }, [])
);
const gif = Boolean(args.gif);
const fps = Number(args.fps ?? (gif ? 15 : 60));
const out = resolve(root, args.out ?? (gif ? "assets/demo.gif" : "dist/demo/whisperlocal-0.2.5-demo.mp4"));
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const profile = mkdtempSync(join(tmpdir(), "wl-demo-"));
const chrome = spawn(chromePath, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
  "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1920,1080",
  "--run-all-compositor-stages-before-draw", "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
  "--allow-file-access-from-files", "--no-first-run", "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

function cleanUp() {
  chrome.kill("SIGTERM");
  // Chrome may still be writing to its profile as it goes; a leftover temp
  // folder is not worth failing a finished render over.
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 3 }); } catch {}
}
process.on("exit", cleanUp);

const wsURL = await new Promise((done, fail) => {
  let text = "";
  chrome.stderr.on("data", (chunk) => {
    text += chunk;
    const found = text.match(/DevTools listening on (ws:\/\/\S+)/);
    if (found) done(found[1]);
  });
  setTimeout(() => fail(new Error("Chrome did not start")), 20000);
});

// A small DevTools Protocol client over Node's built-in WebSocket.
const socket = new WebSocket(wsURL);
await new Promise((done) => socket.addEventListener("open", done, { once: true }));
let nextID = 0;
const waiting = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  const pending = waiting.get(message.id);
  if (!pending) return;
  waiting.delete(message.id);
  if (message.error) pending.fail(new Error(`${pending.method}: ${message.error.message}`));
  else pending.done(message.result);
});
const send = (method, params = {}, sessionId) =>
  new Promise((done, fail) => {
    const id = ++nextID;
    waiting.set(id, { done, fail, method });
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
const page = (method, params) => send(method, params, sessionId);
await page("Page.enable");
await page("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await page("Page.navigate", { url: pathToFileURL(join(here, "index.html")).href + (gif ? "?render=1&gif=1" : "?render=1") });
const evaluate = async (expression) => (await page("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.value;
for (let tries = 0; !(await evaluate("window.__ready === true")); tries++) {
  if (tries > 200) throw new Error("the page never finished building");
  await new Promise((done) => setTimeout(done, 100));
}
const duration = await evaluate("window.DURATION");

async function frameAt(t) {
  await evaluate(`window.renderAt(${t})`);
  const { data } = await page("Page.captureScreenshot", {
    format: "png", optimizeForSpeed: true, captureBeyondViewport: false,
    clip: { x: 0, y: 0, width: 1920, height: 1080, scale: 1 },
  });
  return Buffer.from(data, "base64");
}

if (args.stills) {
  const folder = resolve(root, "dist/demo/stills");
  mkdirSync(folder, { recursive: true });
  for (const t of String(args.stills).split(",").map(Number)) {
    const file = join(folder, `t${t.toFixed(2).padStart(5, "0")}.png`);
    writeFileSync(file, await frameAt(t));
    console.log(file);
  }
  process.exit(0);
}

mkdirSync(dirname(out), { recursive: true });
// A GIF is made in two passes over a near-lossless clip: one palette for the
// whole piece, then every frame mapped onto it.
const clip = gif ? join(dirname(profile), `wl-demo-gif-${process.pid}.mp4`) : out;
const ffmpeg = spawn("ffmpeg", [
  "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
  "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
  "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
  "-crf", gif ? "8" : "16", "-preset", "slow", "-movflags", "+faststart", clip,
], { stdio: ["pipe", "inherit", "inherit"] });
const finished = new Promise((done, fail) => ffmpeg.on("close", (code) => (code === 0 ? done() : fail(new Error(`ffmpeg exited ${code}`)))));

const frames = Math.round(duration * fps);
const started = Date.now();
for (let frame = 0; frame < frames; frame++) {
  const png = await frameAt(frame / fps);
  if (!ffmpeg.stdin.write(png)) await new Promise((done) => ffmpeg.stdin.once("drain", done));
  if (frame % fps === 0 || frame === frames - 1) {
    const elapsed = (Date.now() - started) / 1000;
    process.stdout.write(`\r  frame ${frame + 1}/${frames} · ${elapsed.toFixed(0)} s`);
  }
}
ffmpeg.stdin.end();
await finished;
if (gif) {
  // 720 wide, as the README shows it. Ordered dither keeps the navy gradient
  // the same from frame to frame, so only what moves costs bytes.
  const width = Number(args.width ?? 720);
  const palette = `${clip}.png`;
  const run = (list) => new Promise((done, fail) =>
    spawn("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...list], { stdio: "inherit" })
      .on("close", (code) => (code === 0 ? done() : fail(new Error(`ffmpeg exited ${code}`)))));
  const scale = `scale=${width}:-2:flags=lanczos`;
  await run(["-i", clip, "-vf", `${scale},palettegen=max_colors=256:stats_mode=diff`, palette]);
  await run(["-i", clip, "-i", palette, "-lavfi",
    `${scale}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`, "-loop", "0", out]);
  rmSync(clip, { force: true }); rmSync(palette, { force: true });
  // gifsicle, where installed, drops what repeats between frames (~3%).
  const optimized = spawnSync("gifsicle", ["-O3", "-b", out], { stdio: "inherit" });
  if (optimized.error) console.log("\n(gifsicle not found: left unoptimized)");
}
console.log(`\nwrote ${out}`);
process.exit(0);
