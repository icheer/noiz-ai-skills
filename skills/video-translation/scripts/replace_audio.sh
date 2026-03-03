#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: replace_audio.sh --video <video_file> --audio <audio_file> --output <output_file>

Options:
  --video    Original video file path
  --audio    New audio file path (WAV/MP3)
  --output   Final output video file path
EOF
  exit "${1:-0}"
}

VIDEO=""
AUDIO=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --video)  VIDEO="$2"; shift 2 ;;
    --audio)  AUDIO="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
done

if [[ -z "$VIDEO" || -z "$AUDIO" || -z "$OUTPUT" ]]; then
  echo "Error: --video, --audio, and --output are all required." >&2
  usage 1
fi

if [[ ! -f "$VIDEO" ]]; then
  echo "Error: Video file not found: $VIDEO" >&2
  exit 1
fi

if [[ ! -f "$AUDIO" ]]; then
  echo "Error: Audio file not found: $AUDIO" >&2
  exit 1
fi

# Use ffmpeg to mix the dubbed audio with the original audio track.
# We keep the original video's audio (music, ambience, SFX, etc.) and
# duck it under the dubbed voice wherever the TTS audio is present.
# This relies on the dubbed audio being timeline-aligned to the
# original subtitles (i.e., silent outside subtitle ranges).
echo "Merging original audio from $VIDEO with dubbed track $AUDIO -> $OUTPUT"

# 0.15s fade-in at start reduces clicks; optional fade-out would require duration.
ffmpeg -y -i "$VIDEO" -i "$AUDIO" \
  -filter_complex "\
    [0:a]aformat=channel_layouts=stereo[a0]; \
    [1:a]aformat=channel_layouts=stereo[a1]; \
    [a0][a1]sidechaincompress=threshold=-21dB:ratio=5:attack=5:release=250:makeup=0:mix=0.0[a_orig_ducked]; \
    [a_orig_ducked][a1]amix=inputs=2:weights=1 1[amix]; \
    [amix]afade=t=in:st=0:d=0.15[aout]" \
  -map 0:v:0 -map "[aout]" \
  -c:v copy -c:a aac -b:a 192k \
  -shortest \
  "$OUTPUT"

echo "Done! Output saved to $OUTPUT"
