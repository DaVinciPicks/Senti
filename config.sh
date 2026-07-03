# senti shared config — sourced by every script.
# Edit values here to retune the whole system.

# --- Model ---
# Selected via the menu bar (Fast/Accurate); persisted in model.pref.
#   accurate = large-v3-turbo-q5  (~0.8s, best accuracy, handles proper nouns)
#   fast     = base.en            (~0.3s, English-only, great for clear speech)
WF_MODELS_DIR="$HOME/.local/share/whisper-models"
WF_MODEL_ACCURATE="$WF_MODELS_DIR/ggml-large-v3-turbo-q5_0.bin"
WF_MODEL_FAST="$WF_MODELS_DIR/ggml-base.en.bin"
WF_MODEL_PREF="$HOME/.cache/senti/model.pref"
if [ -z "${WF_MODEL:-}" ]; then
  case "$(cat "$WF_MODEL_PREF" 2>/dev/null)" in
    fast) WF_MODEL="$WF_MODEL_FAST" ;;
    *)    WF_MODEL="$WF_MODEL_ACCURATE" ;;
  esac
fi

# --- Server ---
WF_HOST="${WF_HOST:-127.0.0.1}"
WF_PORT="${WF_PORT:-8090}"
WF_URL="http://${WF_HOST}:${WF_PORT}"

# --- Language --- ("auto" to autodetect, or "en", "es", etc.)
WF_LANG="${WF_LANG:-en}"

# --- Runtime files ---
# --- Custom dictionary (fixes mistranscriptions like "cloud md" → CLAUDE.md) ---
WF_REPLACEMENTS="${WF_REPLACEMENTS:-$HOME/.config/senti/replacements.txt}"

WF_RUN="${WF_RUN:-$HOME/.cache/senti}"
WF_AUDIO="$WF_RUN/capture.wav"
WF_PIDFILE="$WF_RUN/sox.pid"
WF_LOG="$HOME/Library/Logs/senti.log"

# --- AI modes (prompt / command) ---
# Engine priority: DeepSeek (fast ~1.3s, cheap) → claude --bare (if ANTHROPIC key)
# → claude CLI via OAuth (~6s). Drop a key file to enable each path.
WF_DEEPSEEK_KEY="${WF_DEEPSEEK_KEY:-$HOME/.config/senti/deepseek-key}"
WF_DEEPSEEK_MODEL="${WF_DEEPSEEK_MODEL:-deepseek-chat}"
# Context mode (screenshot + voice → context-aware insert) needs a VISION model.
WF_OPENAI_KEY="${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}"
WF_VISION_MODEL="${WF_VISION_MODEL:-gpt-5-nano}"   # cheapest vision (~$0.05/M); gpt-4.1-nano = ~3x faster
WF_OPERATING_PROMPT="${WF_OPERATING_PROMPT:-$HOME/.config/senti/prompts/operating.md}"
WF_APIKEY_FILE="${WF_APIKEY_FILE:-$HOME/.config/senti/api-key}"
if [ -f "$WF_APIKEY_FILE" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  export ANTHROPIC_API_KEY="$(/usr/bin/tr -d '[:space:]' < "$WF_APIKEY_FILE")"
fi

# --- Binaries (absolute paths — Hammerspoon/launchd have a minimal PATH) ---
WF_SOX="${WF_SOX:-/opt/homebrew/bin/sox}"
WF_SERVER="${WF_SERVER:-/opt/homebrew/bin/whisper-server}"
WF_CURL="${WF_CURL:-/usr/bin/curl}"

# --- Audio cues (macOS system sounds; set WF_SOUNDS=0 to silence) ---
WF_SOUNDS="${WF_SOUNDS:-1}"
WF_SOUND_START="${WF_SOUND_START:-/System/Library/Sounds/Tink.aiff}"
WF_SOUND_STOP="${WF_SOUND_STOP:-/System/Library/Sounds/Pop.aiff}"

mkdir -p "$WF_RUN"
