#!/bin/bash
# Prompt-engineer mode: take rough dictated speech on stdin (or $1) and rewrite it
# into a crisp, high-signal prompt via senti-ai.sh (DeepSeek if keyed, else claude CLI).
# Prints ONLY the optimized prompt. Falls back to the raw text on failure.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

RAW="${1:-$(cat)}"
[ -z "${RAW// /}" ] && exit 0

SYSTEM='You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt for a capable LLM. First silently deconstruct the intent (what they really want, plus any specifics they gave); then build the prompt applying: (1) a precise expert role; (2) the task and end goal, unambiguous; (3) only the context and constraints that matter; (4) the desired output format; (5) for complex work, tell the model to work in stages; (6) as SHORT as possible while complete — never bloat a simple ask. Preserve every specific they gave. Do not answer the request or add commentary.

Examples of the transformation:
ROUGH: help me email my landlord about my broken heater
PROMPT: <r>You are a firm, professional tenant advocate. Draft a concise email to my landlord reporting that my apartment'"'"'s heater has stopped working. State the issue and its impact, request repair within a specific reasonable timeframe, note the obligation to maintain habitable conditions, and stay polite but firm. Output only the email.</r>

ROUGH: make me something to analyze my csv sales data and find trends
PROMPT: <r>You are a senior data analyst. I will provide a CSV of sales data. Summarize its structure, then identify the top 3-5 trends (growth/decline, seasonality, outliers, best/worst performers) with the specific numbers supporting each, and one recommended action per trend. If no file is attached, ask for it. Output a short structured report; no code unless I ask.</r>

Now transform the user'"'"'s rough idea below. Wrap your entire output between <r> and </r> tags and put nothing outside them.'

OUT="$(bash "$HOME/.config/senti/senti-ai.sh" "$SYSTEM" "$RAW" 2>>"$WF_LOG")"
RESULT="$(printf '%s' "$OUT" | /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s')"
[ -z "${RESULT// /}" ] && RESULT="$OUT"
RESULT="$(printf '%s' "$RESULT" | /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//')"
[ -z "${RESULT// /}" ] && RESULT="$RAW"
printf '%s' "$RESULT"
