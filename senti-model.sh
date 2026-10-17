#!/bin/bash
# Switch the transcription model and restart the warm server.
#   senti-model.sh fast | accurate | current
set -uo pipefail
source "$HOME/.config/senti/config.sh"
case "${1:-current}" in
  fast)     echo fast     > "$WF_MODEL_PREF" ;;
  accurate) echo accurate > "$WF_MODEL_PREF" ;;
  current)  case "$(cat "$WF_MODEL_PREF" 2>/dev/null)" in fast) echo fast;; *) echo accurate;; esac; exit 0 ;;
  *) echo "usage: senti-model.sh fast|accurate|current" >&2; exit 1 ;;
esac
/bin/launchctl kickstart -k "gui/$(id -u)/io.senti.server" 2>/dev/null
# wait until the freshly-loaded model answers
for _ in $(seq 1 30); do "$WF_CURL" -s -o /dev/null -m1 "$WF_URL/" 2>/dev/null && break; sleep 1; done
echo "$(cat "$WF_MODEL_PREF")"
