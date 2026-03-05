#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOIZ_KEY_FILE="$HOME/.noiz_api_key"
DEFAULT_NOIZ_REF_AUDIO_URL_CN="https://storage.googleapis.com/noiz_audio_public/resource/audio/ref_cn_fm1.WAV"
DEFAULT_NOIZ_REF_AUDIO_URL_EN="https://noiz.ai/resource/img/tts/landing_creative1.mp3"

usage() {
  cat <<'EOF'
Usage:
  tts.sh speak  [options]   — text to audio (simple mode)
  tts.sh speak_and_send_feishu    — speak + send Feishu voice message
  tts.sh speak_and_send_telegram  — speak + send Telegram voice message
  tts.sh speak_and_send_discord   — speak + send Discord voice message
  tts.sh render [options]  — SRT to timeline-accurate audio
  tts.sh to-srt [options]  — text file to SRT with auto timings
  tts.sh config [options]  — check / set NOIZ_API_KEY

Examples:
  tts.sh speak -t "Hello" -v af_sarah -o hello.wav
  tts.sh speak -t "Hi" --ref-audio ./my.wav -o clone.wav
  tts.sh speak_and_send_feishu    -t "你好" --chat-id oc_xxx --app-id cli_xxx --app-secret xxx
  tts.sh speak_and_send_telegram  -t "你好" --chat-id 123456 --bot-token BOT_TOKEN
  tts.sh speak_and_send_discord   -t "Hello" --channel-id 123456 --bot-token BOT_TOKEN
  tts.sh render --srt input.srt --voice-map vm.json -o output.wav
  tts.sh to-srt -i article.txt -o article.srt
  tts.sh config --set-api-key YOUR_KEY
EOF
  exit "${1:-0}"
}

# ── API key persistence ──────────────────────────────────────────────

load_api_key() {
  if [[ -n "${NOIZ_API_KEY:-}" ]]; then
    NOIZ_API_KEY="$(normalize_api_key_base64 "$NOIZ_API_KEY")"
    export NOIZ_API_KEY
    return 0
  fi
  if [[ -f "$NOIZ_KEY_FILE" ]]; then
    NOIZ_API_KEY="$(tr -d '[:space:]' < "$NOIZ_KEY_FILE")"
    NOIZ_API_KEY="$(normalize_api_key_base64 "$NOIZ_API_KEY")"
    export NOIZ_API_KEY
    [[ -n "$NOIZ_API_KEY" ]] && return 0
  fi
  return 1
}

save_api_key() {
  local normalized
  normalized="$(normalize_api_key_base64 "$1")"
  printf '%s' "$normalized" > "$NOIZ_KEY_FILE"
  chmod 600 "$NOIZ_KEY_FILE"
}

normalize_api_key_base64() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import base64
import binascii
import sys

value = sys.argv[1].strip()
if not value:
    print("", end="")
    raise SystemExit(0)

def is_base64(v: str) -> bool:
    padded = v + ("=" * (-len(v) % 4))
    try:
        decoded = base64.b64decode(padded, validate=True)
    except binascii.Error:
        return False
    if not decoded:
        return False
    canonical = base64.b64encode(decoded).decode("ascii").rstrip("=")
    return canonical == v.rstrip("=")

if is_base64(value):
    print(value, end="")
else:
    print(base64.b64encode(value.encode("utf-8")).decode("ascii"), end="")
PY
}

# ── Auto-detect backend ──────────────────────────────────────────────

detect_backend() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return
  fi
  if load_api_key; then
    echo "noiz"
  elif command -v kokoro-tts &>/dev/null && kokoro-tts --help-voices &>/dev/null; then
    echo "kokoro"
  else
    echo ""
  fi
}

# ── Portable mktemp with suffix (macOS mktemp only replaces trailing Xs) ──

_mktemp_suffixed() {
  local base="$1" suffix="$2"
  local tmp
  tmp="$(mktemp "${base}_XXXXXX")"
  mv "$tmp" "${tmp}${suffix}"
  echo "${tmp}${suffix}"
}

# ── Noiz helpers ─────────────────────────────────────────────────────

ensure_noiz_ready() {
  if ! python3 -c "import requests" &>/dev/null; then
    echo "[noiz] Installing requests..." >&2
    uv pip install requests >&2
  fi
}

fetch_voices_list() {
  local api_key="$1" limit="${2:-5}" voice_type="${3:-built-in}" keyword="${4:-whisper}"
  local resp
  resp="$(curl -sS -H "Authorization: ${api_key}" \
    "https://noiz.ai/v1/voices?voice_type=${voice_type}&keyword=${keyword}&skip=0&limit=${limit}" 2>/dev/null)" || true
  if [[ -z "$resp" ]]; then
    echo "  (could not reach Noiz API)" >&2
    return 1
  fi
  echo "$resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', {})
    voices = data.get('voices', [])
    if not voices:
        print('  (no voices found)', file=sys.stderr)
        sys.exit(1)
    for v in voices:
        vid = v.get('voice_id', '?')
        name = v.get('display_name', '?')
        labels = v.get('labels', '')
        print(f'  {vid}  {name}  {labels}')
    total = data.get('total_count', 0)
    shown = len(voices)
    if total > shown:
        print(f'  ... and {total - shown} more')
except Exception:
    print('  (could not parse response)', file=sys.stderr)
    sys.exit(1)
"
}

detect_text_lang() {
  local sample="$1"
  python3 - "$sample" <<'PY'
import sys, re
text = sys.argv[1]
# CJK Unified Ideographs + Extension A/B cover virtually all Chinese characters
if re.search(r'[\u4e00-\u9fff\u3400-\u4dbf]', text):
    print('zh')
else:
    print('en')
PY
}

prepare_ref_audio() {
  local ref_audio_input="$1"
  if [[ "$ref_audio_input" =~ ^https?:// ]]; then
    local tmp_ref
    tmp_ref="$(_mktemp_suffixed /tmp/noiz_ref_audio .wav)"
    echo "[noiz] Downloading reference audio: $ref_audio_input" >&2
    curl -fsSL "$ref_audio_input" -o "$tmp_ref"
    echo "$tmp_ref"
    return 0
  fi
  echo "$ref_audio_input"
}

# ── speak (simple mode) ──────────────────────────────────────────────

cmd_speak() {
  local text="" text_file="" voice="" voice_id="" output="" format="wav"
  local lang="" speed="" emo="" duration="" backend_flag="" ref_audio=""
  local auto_emotion=false similarity_enh=false save_voice=false
  local play_mode=false tmp_output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--text)       text="$2"; shift 2 ;;
      -f|--text-file)  text_file="$2"; shift 2 ;;
      -v|--voice)      voice="$2"; shift 2 ;;
      --voice-id)      voice_id="$2"; shift 2 ;;
      -o|--output)     output="$2"; shift 2 ;;
      --format)        format="$2"; shift 2 ;;
      --lang)          lang="$2"; shift 2 ;;
      --speed)         speed="$2"; shift 2 ;;
      --emo)           emo="$2"; shift 2 ;;
      --duration)      duration="$2"; shift 2 ;;
      --backend)       backend_flag="$2"; shift 2 ;;
      --ref-audio)     ref_audio="$2"; shift 2 ;;
      --auto-emotion)  auto_emotion=true; shift ;;
      --similarity-enh) similarity_enh=true; shift ;;
      --save-voice)    save_voice=true; shift ;;
      -h|--help)       usage 0 ;;
      *) echo "Unknown option: $1"; usage 1 ;;
    esac
  done

  if [[ -z "$output" ]]; then
    play_mode=true
    tmp_output="$(_mktemp_suffixed /tmp/tts_play .wav)"
    output="$tmp_output"
  fi
  if [[ -z "$text" && -z "$text_file" ]]; then
    echo "Error: --text (-t) or --text-file (-f) is required." >&2; exit 1
  fi

  local backend
  backend="$(detect_backend "$backend_flag")"

  if [[ -z "$backend" ]]; then
    echo "Error: no TTS backend available." >&2
    echo "" >&2
    echo "  Option A — Noiz (recommended):" >&2
    echo "    1. Get your API key from https://developers.noiz.ai/api-keys" >&2
    echo "    2. Run: bash skills/tts/scripts/tts.sh config --set-api-key YOUR_KEY" >&2
    echo "" >&2
    echo "  Option B — Kokoro (offline, local):" >&2
    echo "    uv tool install kokoro-tts" >&2
    exit 1
  fi

  if [[ "$backend" == "kokoro" ]]; then
    # Write text to temp file if passed as string
    local input_path="$text_file"
    if [[ -n "$text" ]]; then
      input_path="$(_mktemp_suffixed /tmp/tts_input .txt)"
      printf '%s' "$text" > "$input_path"
    fi

    local cmd=(kokoro-tts "$input_path" "$output" --format "$format")
    [[ -n "$voice" ]] && cmd+=(--voice "$voice")
    [[ -n "$lang" ]]  && cmd+=(--lang "$lang")
    [[ -n "$speed" ]] && cmd+=(--speed "$speed")

    "${cmd[@]}"

    [[ -n "$text" ]] && rm -f "$input_path"
  else
    load_api_key || true
    local api_key="${NOIZ_API_KEY:-}"
    local downloaded_ref_audio=""
    if [[ -z "$api_key" ]]; then
      echo "Error: NOIZ_API_KEY not configured." >&2
      echo "  Get your key at https://developers.noiz.ai/api-keys" >&2
      echo "  Then run: bash skills/tts/scripts/tts.sh config --set-api-key YOUR_KEY" >&2
      exit 1
    fi
    ensure_noiz_ready

    if [[ -z "$voice_id" && -z "$ref_audio" ]]; then
      # Prefer a stable reference voice for daily cloning-style usage.
      # Honour explicit --lang; otherwise detect from text content.
      local _ref_lang="$lang"
      if [[ -z "$_ref_lang" ]]; then
        local _sample="$text"
        if [[ -z "$_sample" && -n "$text_file" ]]; then
          _sample="$(head -c 500 "$text_file")"
        fi
        _ref_lang="$(detect_text_lang "$_sample")"
      fi
      if [[ "$_ref_lang" == "zh" ]]; then
        ref_audio="$DEFAULT_NOIZ_REF_AUDIO_URL_CN"
      else
        ref_audio="$DEFAULT_NOIZ_REF_AUDIO_URL_EN"
      fi
      echo "[noiz] Using default reference audio: $ref_audio" >&2
    fi
    if [[ -n "$ref_audio" && "$ref_audio" =~ ^https?:// ]]; then
      downloaded_ref_audio="$(prepare_ref_audio "$ref_audio")"
      ref_audio="$downloaded_ref_audio"
    fi

    local cmd=(python3 "$SCRIPT_DIR/noiz_tts.py" --api-key "$api_key" --output "$output" --output-format "$format")

    if [[ -n "$text" ]]; then
      cmd+=(--text "$text")
    else
      cmd+=(--text-file "$text_file")
    fi

    [[ -n "$voice_id" ]]  && cmd+=(--voice-id "$voice_id")
    [[ -n "$ref_audio" ]] && cmd+=(--reference-audio "$ref_audio")
    [[ -n "$speed" ]]     && cmd+=(--speed "$speed")
    [[ -n "$emo" ]]       && cmd+=(--emo "$emo")
    [[ -n "$duration" ]]  && cmd+=(--duration "$duration")
    [[ -n "$lang" ]]      && cmd+=(--target-lang "$lang")
    $auto_emotion         && cmd+=(--auto-emotion)
    $similarity_enh       && cmd+=(--similarity-enh)
    $save_voice           && cmd+=(--save-voice)

    "${cmd[@]}"
    [[ -n "$downloaded_ref_audio" ]] && rm -f "$downloaded_ref_audio"
  fi

  if $play_mode; then
    local player=""
    if command -v afplay &>/dev/null; then
      player="afplay"
    elif command -v aplay &>/dev/null; then
      player="aplay"
    elif command -v paplay &>/dev/null; then
      player="paplay"
    else
      echo "[tts] No audio player found (tried afplay, aplay, paplay). Audio saved to: $output" >&2
      return 0
    fi
    echo "[tts] Playing audio..." >&2
    "$player" "$output"
    rm -f "$tmp_output"
  fi
}

# ── third-party senders ───────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/third_party_sender.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/third_party_sender.sh"
fi

# ── render (timeline mode) ───────────────────────────────────────────

cmd_render() {
  local srt="" voice_map="" output="" backend_flag="" extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --srt)        srt="$2"; shift 2 ;;
      --voice-map)  voice_map="$2"; shift 2 ;;
      -o|--output)  output="$2"; shift 2 ;;
      --backend)    backend_flag="$2"; shift 2 ;;
      -h|--help)    usage 0 ;;
      *)            extra_args+=("$1"); shift ;;
    esac
  done

  if [[ -z "$srt" || -z "$voice_map" || -z "$output" ]]; then
    echo "Error: --srt, --voice-map, and --output (-o) are all required." >&2; exit 1
  fi

  local backend
  backend="$(detect_backend "$backend_flag")"
  if [[ -z "$backend" ]]; then
    echo "Error: no TTS backend available." >&2
    echo "" >&2
    echo "  Option A — Noiz (recommended):" >&2
    echo "    1. Get your API key from https://developers.noiz.ai/api-keys" >&2
    echo "    2. Run: bash skills/tts/scripts/tts.sh config --set-api-key YOUR_KEY" >&2
    echo "" >&2
    echo "  Option B — Kokoro (offline, local):" >&2
    echo "    uv tool install kokoro-tts" >&2
    exit 1
  fi

  local cmd=(python3 "$SCRIPT_DIR/render_timeline.py"
    --srt "$srt" --voice-map "$voice_map" --output "$output" --backend "$backend")

  if [[ "$backend" == "noiz" ]]; then
    load_api_key || true
    local api_key="${NOIZ_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
      echo "Error: NOIZ_API_KEY not configured." >&2
      echo "  Get your key at https://developers.noiz.ai/api-keys" >&2
      echo "  Then run: bash skills/tts/scripts/tts.sh config --set-api-key YOUR_KEY" >&2
      exit 1
    fi
    cmd+=(--api-key "$api_key")
  fi

  cmd+=("${extra_args[@]}")
  "${cmd[@]}"
}

# ── to-srt ────────────────────────────────────────────────────────────

cmd_to_srt() {
  local input="" output="" cps="" gap=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--input)   input="$2"; shift 2 ;;
      -o|--output)  output="$2"; shift 2 ;;
      --cps)        cps="$2"; shift 2 ;;
      --gap)        gap="$2"; shift 2 ;;
      -h|--help)    usage 0 ;;
      *) echo "Unknown option: $1"; usage 1 ;;
    esac
  done

  if [[ -z "$input" || -z "$output" ]]; then
    echo "Error: --input (-i) and --output (-o) are required." >&2; exit 1
  fi

  local cmd=(python3 "$SCRIPT_DIR/text_to_srt.py" --input "$input" --output "$output")
  [[ -n "$cps" ]] && cmd+=(--chars-per-second "$cps")
  [[ -n "$gap" ]] && cmd+=(--gap-ms "$gap")

  "${cmd[@]}"
}

# ── config ─────────────────────────────────────────────────────────────

cmd_config() {
  local set_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set-api-key) set_key="$2"; shift 2 ;;
      -h|--help) echo "Usage: tts.sh config [--set-api-key KEY]"; exit 0 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -n "$set_key" ]]; then
    save_api_key "$set_key"
    echo "API key saved to $NOIZ_KEY_FILE"
    return 0
  fi

  if load_api_key; then
    local masked="${NOIZ_API_KEY:0:4}****${NOIZ_API_KEY: -4}"
    echo "NOIZ_API_KEY is configured: $masked"
  else
    cat <<GUIDE
NOIZ_API_KEY is not configured.

Option A — Noiz (recommended):
  1. Get your API key from https://developers.noiz.ai/api-keys
  2. Run:
     bash skills/tts/scripts/tts.sh config --set-api-key YOUR_KEY
  The key will be saved to $NOIZ_KEY_FILE and loaded automatically.

Option B — Kokoro (offline, local):
  uv tool install kokoro-tts
GUIDE
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────

_dispatch_sender() {
  local func="$1"; shift
  if ! declare -F "$func" >/dev/null; then
    echo "Error: third-party sender module not loaded ($SCRIPT_DIR/third_party_sender.sh)." >&2
    exit 1
  fi
  "$func" "$@"
}

case "${1:-}" in
  speak)   shift; cmd_speak "$@" ;;
  speak_and_send_feishu|speak-and-send-feishu)
    shift; _dispatch_sender cmd_speak_and_send_feishu "$@" ;;
  speak_and_send_telegram|speak-and-send-telegram)
    shift; _dispatch_sender cmd_speak_and_send_telegram "$@" ;;
  speak_and_send_discord|speak-and-send-discord)
    shift; _dispatch_sender cmd_speak_and_send_discord "$@" ;;
  render)  shift; cmd_render "$@" ;;
  to-srt)  shift; cmd_to_srt "$@" ;;
  config)  shift; cmd_config "$@" ;;
  -h|--help|"") usage 0 ;;
  *) echo "Unknown command: $1"; usage 1 ;;
esac
