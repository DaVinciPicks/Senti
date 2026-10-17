#!/bin/bash
# Runs the whisper-server daemon that keeps the model warm in memory.
# Invoked by launchd (io.senti.server) and kept alive across reboots.
set -euo pipefail
source "$HOME/.config/senti/config.sh"

# Optional domain vocabulary bias (proper nouns, jargon). Empty by default.
PROMPT_ARGS=()
[ -n "${WF_PROMPT:-}" ] && PROMPT_ARGS=(--prompt "$WF_PROMPT")

exec "$WF_SERVER" \
  -m "$WF_MODEL" \
  --host "$WF_HOST" \
  --port "$WF_PORT" \
  --language "$WF_LANG" \
  --threads 6 \
  --no-timestamps \
  --suppress-nst \
  --no-fallback \
  --best-of 1 \
  ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"}
