#!/bin/bash
# Command Mode: apply a spoken instruction to the currently-selected text (or, if
# nothing is selected, generate text for the cursor) via senti-ai.sh (DeepSeek/claude).
#   $1 = the spoken command (transcribed)
#   $2 = path to a file containing the selected text (may be empty/absent)
# Prints ONLY the text to insert. Falls back to the original selection on failure.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

# Spoken command arrives in SENTI_IN, never argv (see senti-ai.sh).
CMD="${SENTI_IN:-${1:-}}"
SELFILE="${2:-}"
SEL=""
[ -n "$SELFILE" ] && [ -f "$SELFILE" ] && SEL="$(cat "$SELFILE")"
[ -z "${CMD// /}" ] && { printf '%s' "$SEL"; exit 0; }

WRAP='Wrap your entire output between <r> and </r> tags and put NOTHING outside them — no preamble, no explanation, no quotes, no markdown fences. Example: <r>your result here</r>'
if [ -n "${SEL// /}" ]; then
  SYS="You are an inline text editor inside the user's document. They selected some text and spoke a command to transform it. Apply the command to the SELECTED TEXT and produce the replacement text, matching the surrounding style and preserving meaning unless told otherwise. $WRAP"
  INPUT="COMMAND: $CMD

SELECTED TEXT:
$SEL"
else
  SYS="You are an inline writing assistant. The user placed their cursor in a text field and spoke a request. Produce the text to insert at the cursor. $WRAP"
  INPUT="REQUEST: $CMD"
fi

OUT="$(SENTI_IN="$INPUT" bash "$HOME/.config/senti/senti-ai.sh" "$SYS" 2>>"$WF_LOG")"

# Extract only what's between the sentinel tags (discards any stray preamble).
RESULT="$(printf '%s' "$OUT" | /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s')"
[ -z "${RESULT// /}" ] && RESULT="$OUT"          # fallback if the model omitted tags
RESULT="$(printf '%s' "$RESULT" | /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//')"
[ -z "${RESULT// /}" ] && RESULT="$SEL"          # last resort: leave selection unchanged
printf '%s' "$RESULT"
