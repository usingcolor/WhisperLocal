#!/usr/bin/env bash
# Record a short screen clip and encode it for a README.
#
# The dictation itself has to be performed live — that is the product. Everything
# around it (region, duration, trimming, encoding, size) is handled here so the
# only job left is to speak.
#
#   bash scripts/record-demo.sh                 # 12s, centred 1280x720 region
#   bash scripts/record-demo.sh 15              # 15s
#   bash scripts/record-demo.sh 15 100,200,1280,720
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

seconds="${1:-12}"
region="${2:-}"
out_dir="dist/demo"
raw="$out_dir/raw.mov"
final="$out_dir/demo.mp4"
mkdir -p "$out_dir"

if [[ -z "$region" ]]; then
  # Centre a 1280x720 box on the main display.
  read -r sw sh <<<"$(osascript -e 'tell application "Finder" to get bounds of window of desktop' \
    | awk -F', *' '{print $3, $4}')"
  x=$(( (sw - 1280) / 2 )); y=$(( (sh - 720) / 2 ))
  (( x < 0 )) && x=0; (( y < 0 )) && y=0
  region="${x},${y},1280,720"
fi

cat <<EOF
Recording ${seconds}s of region ${region}

  1. Put the cursor in a text field inside that region.
  2. Wait for "GO", then hold the hotkey and dictate.
  3. Let go and let the text land before it stops.

Starting in 3...
EOF
sleep 1; echo "2..."; sleep 1; echo "1..."; sleep 1; echo "GO"

rm -f "$raw"
screencapture -v -V "$seconds" -R "$region" "$raw"

if [[ ! -s "$raw" ]]; then
  echo "error: nothing was recorded. Screen Recording permission is needed for the" >&2
  echo "       terminal running this: System Settings > Privacy & Security > Screen Recording." >&2
  exit 1
fi

# 720 wide, even dimensions for yuv420p, no audio, faststart so it plays inline.
ffmpeg -hide_banner -loglevel error -y -i "$raw" \
  -vf "scale=720:-2:flags=lanczos,fps=30" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 26 -preset slow \
  -movflags +faststart -an "$final"

bytes=$(wc -c < "$final" | tr -d ' ')
printf '\ndone: %s  (%s, %.1f MB)\n' "$final" "$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,duration -of csv=p=0 "$final")" "$(echo "$bytes/1048576" | bc -l)"
echo
echo "Next: drag it into a GitHub issue comment, copy the URL GitHub gives back,"
echo "and put that in the demo slot near the top of README.md."
