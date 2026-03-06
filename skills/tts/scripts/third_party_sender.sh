# Third-party sender integrations for tts.sh.
# This file is sourced by tts.sh after cmd_speak is defined.
#
# Supported platforms:
#   - Feishu   (speak_and_send_feishu)
#   - Telegram (speak_and_send_telegram)
#   - Discord  (speak_and_send_discord)

# ── Shared helpers ────────────────────────────────────────────────────

_sender_require() {
  local cmd="$1" label="${2:-sender}"
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required for $label." >&2
    exit 1
  fi
}

_json_field() {
  local json_text="$1" field_expr="$2"
  python3 - "$json_text" "$field_expr" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    obj = obj.get(key) if isinstance(obj, dict) else None
    if obj is None:
        break
if obj is None:
    print("")
elif isinstance(obj, (dict, list)):
    print(json.dumps(obj, ensure_ascii=False))
else:
    print(obj)
PY
}

_read_audio_duration_secs() {
  local dur_file="${1%.*}.duration"
  if [[ -f "$dur_file" ]]; then
    tr -d '[:space:]' < "$dur_file"
  else
    echo "-1"
  fi
}

_audio_duration_ms() {
  local secs
  secs="$(_read_audio_duration_secs "$1")"
  python3 -c "print(max(1, int(float('${secs}') * 1000)))"
}

_build_speak_args() {
  _SPEAK_ARGS=(--output "$1" --format opus)
  [[ -n "${_SA_TEXT:-}" ]]       && _SPEAK_ARGS+=(--text "$_SA_TEXT")
  [[ -n "${_SA_TEXT_FILE:-}" ]]  && _SPEAK_ARGS+=(--text-file "$_SA_TEXT_FILE")
  [[ -n "${_SA_VOICE:-}" ]]     && _SPEAK_ARGS+=(--voice "$_SA_VOICE")
  [[ -n "${_SA_VOICE_ID:-}" ]]  && _SPEAK_ARGS+=(--voice-id "$_SA_VOICE_ID")
  [[ -n "${_SA_LANG:-}" ]]      && _SPEAK_ARGS+=(--lang "$_SA_LANG")
  [[ -n "${_SA_SPEED:-}" ]]     && _SPEAK_ARGS+=(--speed "$_SA_SPEED")
  [[ -n "${_SA_EMO:-}" ]]       && _SPEAK_ARGS+=(--emo "$_SA_EMO")
  [[ -n "${_SA_DURATION:-}" ]]  && _SPEAK_ARGS+=(--duration "$_SA_DURATION")
  [[ -n "${_SA_BACKEND:-}" ]]   && _SPEAK_ARGS+=(--backend "$_SA_BACKEND")
  [[ -n "${_SA_REF_AUDIO:-}" ]] && _SPEAK_ARGS+=(--ref-audio "$_SA_REF_AUDIO")
  ${_SA_AUTO_EMOTION:-false}    && _SPEAK_ARGS+=(--auto-emotion)
  ${_SA_SIMILARITY_ENH:-false}  && _SPEAK_ARGS+=(--similarity-enh)
  ${_SA_SAVE_VOICE:-false}      && _SPEAK_ARGS+=(--save-voice)
}

_parse_common_speak_opts() {
  _SA_TEXT="" _SA_TEXT_FILE="" _SA_VOICE="" _SA_VOICE_ID=""
  _SA_LANG="" _SA_SPEED="" _SA_EMO="" _SA_DURATION=""
  _SA_BACKEND="" _SA_REF_AUDIO=""
  _SA_AUTO_EMOTION=false _SA_SIMILARITY_ENH=false _SA_SAVE_VOICE=false
  _SA_KEEP_AUDIO=false _SA_AUDIO_OUTPUT=""
  _SA_REMAINING=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--text)         _SA_TEXT="$2"; shift 2 ;;
      -f|--text-file)    _SA_TEXT_FILE="$2"; shift 2 ;;
      -v|--voice)        _SA_VOICE="$2"; shift 2 ;;
      --voice-id)        _SA_VOICE_ID="$2"; shift 2 ;;
      -o|--output)       _SA_AUDIO_OUTPUT="$2"; shift 2 ;;
      --lang)            _SA_LANG="$2"; shift 2 ;;
      --speed)           _SA_SPEED="$2"; shift 2 ;;
      --emo)             _SA_EMO="$2"; shift 2 ;;
      --duration)        _SA_DURATION="$2"; shift 2 ;;
      --backend)         _SA_BACKEND="$2"; shift 2 ;;
      --ref-audio)       _SA_REF_AUDIO="$2"; shift 2 ;;
      --auto-emotion)    _SA_AUTO_EMOTION=true; shift ;;
      --similarity-enh)  _SA_SIMILARITY_ENH=true; shift ;;
      --save-voice)      _SA_SAVE_VOICE=true; shift ;;
      --keep-audio)      _SA_KEEP_AUDIO=true; shift ;;
      *)                 _SA_REMAINING+=("$1"); shift ;;
    esac
  done
}

_save_opus_if_requested() {
  local opus_path="$1"
  if $_SA_KEEP_AUDIO; then
    if [[ -z "$_SA_AUDIO_OUTPUT" ]]; then
      _SA_AUDIO_OUTPUT="./tts_$(date +%Y%m%d_%H%M%S).opus"
    fi
    cp "$opus_path" "$_SA_AUDIO_OUTPUT"
    echo "Saved opus audio: $_SA_AUDIO_OUTPUT" >&2
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  Feishu
# ══════════════════════════════════════════════════════════════════════

_feishu_get_token() {
  local app_id="$1" app_secret="$2"
  local resp code msg token
  resp="$(curl -sS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"app_id\":\"$app_id\",\"app_secret\":\"$app_secret\"}")"
  code="$(_json_field "$resp" "code")"
  if [[ "$code" != "0" ]]; then
    msg="$(_json_field "$resp" "msg")"
    echo "Error: Feishu tenant_access_token failed. code=$code msg=$msg" >&2
    exit 1
  fi
  token="$(_json_field "$resp" "tenant_access_token")"
  if [[ -z "$token" ]]; then
    echo "Error: Feishu tenant_access_token is empty." >&2
    exit 1
  fi
  printf '%s' "$token"
}

cmd_speak_and_send_feishu() {
  _parse_common_speak_opts "$@"
  set -- "${_SA_REMAINING[@]}"

  local chat_id="${FEISHU_CHAT_ID:-}"
  local app_id="${FEISHU_APP_ID:-}" app_secret="${FEISHU_APP_SECRET:-}"
  local tenant_access_token="${FEISHU_TENANT_ACCESS_TOKEN:-}"
  local feishu_base_url="${FEISHU_BASE_URL:-https://open.feishu.cn/open-apis}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chat-id)              chat_id="$2"; shift 2 ;;
      --app-id)               app_id="$2"; shift 2 ;;
      --app-secret)           app_secret="$2"; shift 2 ;;
      --tenant-access-token)  tenant_access_token="$2"; shift 2 ;;
      --feishu-base-url)      feishu_base_url="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: tts.sh speak_and_send_feishu [speak options] --chat-id CHAT_ID [auth]

Auth (choose one):
  --tenant-access-token TOKEN
  --app-id APP_ID --app-secret APP_SECRET

Env: FEISHU_CHAT_ID, FEISHU_APP_ID, FEISHU_APP_SECRET,
     FEISHU_TENANT_ACCESS_TOKEN, FEISHU_BASE_URL

Flow:
  1) Upload opus file  (file_type=opus, receive_id_type=chat_id)
  2) Send audio message (msg_type=audio, content={file_key,duration})
EOF
        exit 0 ;;
      *) echo "Unknown feishu option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -z "$chat_id" ]] && { echo "Error: --chat-id required (or FEISHU_CHAT_ID)." >&2; exit 1; }
  if [[ -z "$tenant_access_token" && ( -z "$app_id" || -z "$app_secret" ) ]]; then
    echo "Error: provide --tenant-access-token or (--app-id + --app-secret)." >&2; exit 1
  fi

  _sender_require curl feishu
  _sender_require python3 feishu

  local tts_opus dur_file
  tts_opus="$(_mktemp_suffixed /tmp/tts_feishu .opus)"
  dur_file="${tts_opus%.*}.duration"
  trap 'rm -f "$tts_opus" "$dur_file"' EXIT

  _build_speak_args "$tts_opus"
  cmd_speak "${_SPEAK_ARGS[@]}"

  local duration_ms
  duration_ms="$(_audio_duration_ms "$tts_opus")"

  [[ -z "$tenant_access_token" ]] && \
    tenant_access_token="$(_feishu_get_token "$app_id" "$app_secret")"

  local upload_resp upload_code file_key
  upload_resp="$(curl -sS -X POST \
    "${feishu_base_url%/}/im/v1/files?receive_id_type=chat_id&receive_id=$chat_id" \
    -H "Authorization: Bearer ${tenant_access_token}" \
    -F "file_type=opus" \
    -F "file=@${tts_opus};type=audio/ogg" \
    -F "file_name=tts.opus")"
  upload_code="$(_json_field "$upload_resp" "code")"
  if [[ "$upload_code" != "0" ]]; then
    echo "Error: Feishu upload failed. code=$upload_code msg=$(_json_field "$upload_resp" "msg")" >&2
    exit 1
  fi
  file_key="$(_json_field "$upload_resp" "data.file_key")"
  [[ -z "$file_key" ]] && { echo "Error: Feishu file_key is empty." >&2; exit 1; }

  local content_json send_resp send_code message_id
  content_json="$(python3 -c "import json; print(json.dumps({'file_key':'$file_key','duration':$duration_ms}))")"
  send_resp="$(curl -sS -X POST \
    "${feishu_base_url%/}/im/v1/messages?receive_id_type=chat_id" \
    -H "Authorization: Bearer ${tenant_access_token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(python3 -c "import json; print(json.dumps({'receive_id':'$chat_id','msg_type':'audio','content':json.dumps({'file_key':'$file_key','duration':$duration_ms})}))")")"
  send_code="$(_json_field "$send_resp" "code")"
  if [[ "$send_code" != "0" ]]; then
    echo "Error: Feishu send failed. code=$send_code msg=$(_json_field "$send_resp" "msg")" >&2
    exit 1
  fi
  message_id="$(_json_field "$send_resp" "data.message_id")"
  echo "Done. Feishu voice sent. chat_id=$chat_id file_key=$file_key duration_ms=$duration_ms message_id=${message_id:-unknown}" >&2

  _save_opus_if_requested "$tts_opus"
}

# ══════════════════════════════════════════════════════════════════════
#  Telegram
# ══════════════════════════════════════════════════════════════════════

cmd_speak_and_send_telegram() {
  _parse_common_speak_opts "$@"
  set -- "${_SA_REMAINING[@]}"

  local chat_id="${TELEGRAM_CHAT_ID:-}"
  local bot_token="${TELEGRAM_BOT_TOKEN:-}"
  local api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chat-id)    chat_id="$2"; shift 2 ;;
      --bot-token)  bot_token="$2"; shift 2 ;;
      --api-base)   api_base="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: tts.sh speak_and_send_telegram [speak options] --chat-id CHAT_ID --bot-token TOKEN

Env: TELEGRAM_CHAT_ID, TELEGRAM_BOT_TOKEN, TELEGRAM_API_BASE

Flow:
  1) TTS → opus
  2) POST /sendVoice with voice=@file.opus (multipart)
EOF
        exit 0 ;;
      *) echo "Unknown telegram option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -z "$bot_token" ]] && { echo "Error: --bot-token required (or TELEGRAM_BOT_TOKEN)." >&2; exit 1; }
  [[ -z "$chat_id" ]]   && { echo "Error: --chat-id required (or TELEGRAM_CHAT_ID)." >&2; exit 1; }

  _sender_require curl telegram
  _sender_require python3 telegram

  local tts_opus dur_file
  tts_opus="$(_mktemp_suffixed /tmp/tts_telegram .opus)"
  dur_file="${tts_opus%.*}.duration"
  trap 'rm -f "$tts_opus" "$dur_file"' EXIT

  _build_speak_args "$tts_opus"
  cmd_speak "${_SPEAK_ARGS[@]}"

  local dur_secs
  dur_secs="$(printf '%.0f' "$(_read_audio_duration_secs "$tts_opus")")"

  local resp ok msg_id
  resp="$(curl -sS -X POST "${api_base%/}/bot${bot_token}/sendVoice" \
    -F "chat_id=$chat_id" \
    -F "voice=@${tts_opus};type=audio/ogg" \
    -F "duration=$dur_secs")"
  ok="$(_json_field "$resp" "ok")"
  if [[ "$ok" != "True" && "$ok" != "true" ]]; then
    echo "Error: Telegram sendVoice failed. response=$resp" >&2
    exit 1
  fi
  msg_id="$(_json_field "$resp" "result.message_id")"
  echo "Done. Telegram voice sent. chat_id=$chat_id duration=${dur_secs}s message_id=${msg_id:-unknown}" >&2

  _save_opus_if_requested "$tts_opus"
}

# ══════════════════════════════════════════════════════════════════════
#  Discord
# ══════════════════════════════════════════════════════════════════════

_discord_generate_waveform() {
  python3 - "$1" <<'PY'
import base64, hashlib, math, sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
seed = int.from_bytes(hashlib.md5(data).digest()[:4], "little")
n_bars = 256
bars = []
for i in range(n_bars):
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    noise = (seed >> 16) % 40 - 20
    val = int(140 + 70 * math.sin(i * 0.12) + noise)
    bars.append(max(0, min(255, val)))
print(base64.b64encode(bytes(bars)).decode())
PY
}

cmd_speak_and_send_discord() {
  _parse_common_speak_opts "$@"
  set -- "${_SA_REMAINING[@]}"

  local channel_id="${DISCORD_CHANNEL_ID:-}"
  local bot_token="${DISCORD_BOT_TOKEN:-}"
  local api_base="${DISCORD_API_BASE:-https://discord.com/api/v10}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel-id) channel_id="$2"; shift 2 ;;
      --bot-token)  bot_token="$2"; shift 2 ;;
      --api-base)   api_base="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: tts.sh speak_and_send_discord [speak options] --channel-id ID --bot-token TOKEN

Env: DISCORD_CHANNEL_ID, DISCORD_BOT_TOKEN, DISCORD_API_BASE

Flow:
  1) TTS → opus
  2) Request attachment upload slot
  3) PUT audio to upload URL
  4) POST message with flags=8192 (voice), waveform, duration_secs
EOF
        exit 0 ;;
      *) echo "Unknown discord option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -z "$bot_token" ]]  && { echo "Error: --bot-token required (or DISCORD_BOT_TOKEN)." >&2; exit 1; }
  [[ -z "$channel_id" ]] && { echo "Error: --channel-id required (or DISCORD_CHANNEL_ID)." >&2; exit 1; }

  _sender_require curl discord
  _sender_require python3 discord

  local tts_opus dur_file
  tts_opus="$(_mktemp_suffixed /tmp/tts_discord .opus)"
  dur_file="${tts_opus%.*}.duration"
  trap 'rm -f "$tts_opus" "$dur_file"' EXIT

  _build_speak_args "$tts_opus"
  cmd_speak "${_SPEAK_ARGS[@]}"

  local file_size dur_secs waveform_b64
  file_size="$(wc -c < "$tts_opus" | tr -d ' ')"
  dur_secs="$(_read_audio_duration_secs "$tts_opus")"
  waveform_b64="$(_discord_generate_waveform "$tts_opus")"

  local auth_header="Bot ${bot_token}"

  # Step 1: request attachment upload slot
  local slot_resp upload_url uploaded_filename
  slot_resp="$(curl -sS -X POST "${api_base%/}/channels/${channel_id}/attachments" \
    -H "Authorization: $auth_header" \
    -H "Content-Type: application/json" \
    -d "{\"files\":[{\"file_size\":$file_size,\"filename\":\"voice.ogg\",\"id\":\"0\"}]}")"
  upload_url="$(_json_field "$slot_resp" "attachments" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())[0]['upload_url'])")"
  uploaded_filename="$(_json_field "$slot_resp" "attachments" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())[0]['upload_filename'])")"
  if [[ -z "$upload_url" || -z "$uploaded_filename" ]]; then
    echo "Error: Discord attachment slot failed. response=$slot_resp" >&2
    exit 1
  fi

  # Step 2: upload audio file
  local upload_status
  upload_status="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$upload_url" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${tts_opus}")"
  if [[ "$upload_status" != "200" ]]; then
    echo "Error: Discord file upload failed. HTTP $upload_status" >&2
    exit 1
  fi

  # Step 3: send voice message (flags 8192 = IS_VOICE_MESSAGE)
  local msg_payload msg_resp msg_id
  msg_payload="$(python3 - "$uploaded_filename" "$dur_secs" "$waveform_b64" <<'PY'
import json, sys
print(json.dumps({
    "flags": 8192,
    "attachments": [{
        "id": "0",
        "filename": "voice.ogg",
        "uploaded_filename": sys.argv[1],
        "duration_secs": round(float(sys.argv[2]), 2),
        "waveform": sys.argv[3],
    }]
}))
PY
)"
  msg_resp="$(curl -sS -X POST "${api_base%/}/channels/${channel_id}/messages" \
    -H "Authorization: $auth_header" \
    -H "Content-Type: application/json" \
    -d "$msg_payload")"
  msg_id="$(_json_field "$msg_resp" "id")"
  if [[ -z "$msg_id" ]]; then
    echo "Error: Discord send failed. response=$msg_resp" >&2
    exit 1
  fi
  echo "Done. Discord voice sent. channel_id=$channel_id duration=${dur_secs}s message_id=$msg_id" >&2

  _save_opus_if_requested "$tts_opus"
}
