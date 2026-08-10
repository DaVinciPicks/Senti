# senti shared config — sourced by every script.
# Edit values here to retune the whole system.
#
# NOTE: install.sh only copies this file if it is MISSING, so your local edits
# survive a `git pull`. When the schema changes, WF_CONFIG_VERSION is bumped and
# install.sh backs your old file up to config.sh.bak rather than silently keeping
# stale settings. Model IDs deliberately do NOT live here anymore — they are
# defaults at the point of use in each script, so an upgrade actually upgrades.
# Override one anyway by uncommenting it below.
# v3: WF_EFFORT default low→none (2.2x cheaper, 1.8x faster at equal quality), plus
#     per-mode WF_JUDGE_EFFORT / WF_VISION_EFFORT and a tunable WF_SHOT_PX.
# v4: default model gpt-5.4-mini → gpt-5.6-luna (newer, 3-4.5x cheaper, eval 8.12 vs 8.00).
# v5: Best mode deleted (unreachable from the live path, never measured better, 2x latency);
#     second-brain bridge added (WF_BRAIN* — Obsidian vault digests in prompt mode).
WF_CONFIG_VERSION=5

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

# --- Custom dictionary (fixes mistranscriptions like "cloud md" → CLAUDE.md) ---
WF_REPLACEMENTS="${WF_REPLACEMENTS:-$HOME/.config/senti/replacements.txt}"

# --- Runtime files ---
WF_RUN="${WF_RUN:-$HOME/.cache/senti}"
WF_AUDIO="$WF_RUN/capture.wav"
WF_PIDFILE="$WF_RUN/sox.pid"
WF_LOG="$HOME/Library/Logs/senti.log"

# --- AI modes (prompt / command / context) ---
# One provider, one key, one model: OpenAI gpt-5.6-luna ($0.20/$1.20 per 1M).
# Measured on this Mac (8-case eval + per-call cost):
#   gpt-4o-mini   vision 3.30s  37k tok  $0.00560   (the old vision model)
#   deepseek-chat text   1.37s           $0.00003   (the old text model — still cheapest)
#   gpt-5.4-mini  8.00   text  $0.00155  vision $0.00177
#   gpt-5.6-luna  8.12   text  $0.00049  vision $0.00039   ← default
#   gpt-5.6-terra 8.25   text  $0.00568   (+0.25 eval for ~12x luna's cost — not worth it)
# Eval granularity is integer scores over 8 cases, so ±0.25 is noise; luna is chosen
# because it is newer and 3-4.5x cheaper at indistinguishable quality, not because 8.12>8.00.
# For a one-off quality push: WF_TEXT_MODEL=gpt-5.6-sol bash senti-prompt.sh ...
WF_OPENAI_KEY="${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}"
# Reasoning depth: none | low | medium | high | xhigh   ('minimal' is REJECTED by gpt-5.x)
# Measured on the prompt-rewrite task (2 runs each): none 2.05s/$0.00115 ·
# low 3.68s/$0.00254 · medium 8.43s/$0.00597. Rewriting a prompt is a transformation,
# not a reasoning problem, so `none` is 2.2x cheaper AND 1.8x faster at the same quality —
# the 269 reasoning tokens `low` spends here are pure overhead.
WF_EFFORT="${WF_EFFORT:-none}"
# The judge (eval harness / pairwise compare) does comparative reasoning — pay for depth there.
WF_JUDGE_EFFORT="${WF_JUDGE_EFFORT:-low}"
# Vision: reading a screen benefits from a little reasoning and it's cheap there
# (~45 output tokens either way).
WF_VISION_EFFORT="${WF_VISION_EFFORT:-low}"
# Screenshot long edge sent to the vision model. Measured cost/quality:
#   1024 → 843 tok / $0.00088 (reads on-screen text, misses fine detail)
#   1536 → 1880 tok / $0.00161 (reads exact commands/filenames — the default)
#   2048 → 2814 tok / $0.00233 (no material gain over 1536)
# Drop to 1024 to roughly halve vision cost if you don't need fine text read back.
WF_SHOT_PX="${WF_SHOT_PX:-1536}"
# Uncomment to pin a model; otherwise each script's built-in default is used
# (so upgrades take effect without editing this file).
# WF_TEXT_MODEL="gpt-5.6-luna"
# WF_VISION_MODEL="gpt-5.6-luna"

WF_OPERATING_PROMPT="${WF_OPERATING_PROMPT:-$HOME/.config/senti/prompts/operating.md}"
# Model-aware prompting knowledge base: prompt mode reads the guidance file for
# whichever model you're actually about to paste into. See prompts/models/.
WF_MODEL_KB="${WF_MODEL_KB:-$HOME/.config/senti/prompts/models}"
# Optional manual pin for the target-model family (no UI writes this — it's an
# escape hatch): `echo anthropic > ~/.cache/senti/target.pref`. Absent/"auto" =
# detect from the frontmost app / browser tab title.
WF_TARGET_PREF="${WF_TARGET_PREF:-$HOME/.cache/senti/target.pref}"

# --- Second brain (Obsidian) ---
# Prompt mode injects a capped digest of YOUR vault note for the current project.
# The digest rides the API call — that's the point and the risk. Only allowlisted
# dirs are searched, size is capped, every injection is logged to senti.log.
# Defaults live in senti-brain.sh; override here if needed:
# WF_BRAIN=0                                  # kill switch
# WF_VAULT="$HOME/Documents/Obsidian Vault"
# WF_BRAIN_MAX=700                            # digest cap, chars
# WF_BRAIN_REFRESH=0                          # disable the background luna digest (~$0.001)

# --- Binaries (absolute paths — Hammerspoon/launchd have a minimal PATH) ---
WF_SOX="${WF_SOX:-/opt/homebrew/bin/sox}"
WF_SERVER="${WF_SERVER:-/opt/homebrew/bin/whisper-server}"
WF_CURL="${WF_CURL:-/usr/bin/curl}"

# --- Audio cues (macOS system sounds; set WF_SOUNDS=0 to silence) ---
WF_SOUNDS="${WF_SOUNDS:-1}"
WF_SOUND_START="${WF_SOUND_START:-/System/Library/Sounds/Tink.aiff}"
WF_SOUND_STOP="${WF_SOUND_STOP:-/System/Library/Sounds/Pop.aiff}"

mkdir -p "$WF_RUN"
