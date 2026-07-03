#!/bin/bash
# Prompt-engineer mode: take rough dictated speech on stdin (or $1) and rewrite it
# into a crisp, high-signal prompt via senti-ai.sh (DeepSeek if keyed, else claude CLI).
# Prints ONLY the optimized prompt. Falls back to the raw text on failure.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

RAW="${1:-$(cat)}"
[ -z "${RAW// /}" ] && exit 0

SYSTEM='You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt that gets an excellent result from a capable LLM. Apply these principles: (1) assign a precise expert role; (2) state the task and end goal unambiguously; (3) include only the context and constraints that actually matter; (4) specify the desired output format; (5) for complex work, instruct the model to think step by step or break it into stages; (6) keep it as SHORT as possible while complete — never pad a simple request into a bloated one. Preserve the user intent and every specific they gave. Do not answer the request or add commentary. Wrap your entire output between <r> and </r> tags and put nothing outside them.'

OUT="$(bash "$HOME/.config/senti/senti-ai.sh" "$SYSTEM" "$RAW" 2>>"$WF_LOG")"
RESULT="$(printf '%s' "$OUT" | /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s')"
[ -z "${RESULT// /}" ] && RESULT="$OUT"
RESULT="$(printf '%s' "$RESULT" | /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//')"
[ -z "${RESULT// /}" ] && RESULT="$RAW"
printf '%s' "$RESULT"
