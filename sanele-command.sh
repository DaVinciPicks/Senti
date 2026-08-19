#!/bin/bash
# Command Mode: apply a spoken instruction to the currently-selected text (or, if
# nothing is selected, generate text for the cursor) via sanele-ai.sh (gpt-5.6-luna).
#   $1 = the spoken command (transcribed)
#   $2 = path to a file containing the selected text (may be empty/absent)
# Prints ONLY the text to insert. Falls back to the original selection on failure.
set -uo pipefail
source "$HOME/.config/sanele/config.sh"

# PERF: never use ${VAR// /} to test for blankness here. macOS ships bash 3.2, where
# that substitution is O(n^2) on strings containing spaces — MEASURED 1K:17ms, 2K:72ms,
# 4K:492ms, 8K:3720ms. This script ran it four times per call on the user's SELECTION,
# so transforming a few paragraphs stalled for seconds and a large selection blew the
# 75s watchdog: the HUD reset to idle and the late callback pasted into whatever app the
# user had moved to. The case-glob below is 6ms flat at 32KB.
# Semantics note: this treats an all-whitespace string (tabs/newlines) as blank, whereas
# ${VAR// /} only stripped literal spaces. That is the behaviour we actually want for
# "did the user select anything meaningful".
blank() { case "$1" in *[![:space:]]*) return 1 ;; *) return 0 ;; esac; }

# Spoken command arrives in SANELE_IN, never argv (see sanele-ai.sh).
CMD="${SANELE_IN:-${1:-}}"
SELFILE="${2:-}"
SEL=""
[ -n "$SELFILE" ] && [ -f "$SELFILE" ] && SEL="$(cat "$SELFILE")"
blank "$CMD" && { printf '%s' "$SEL"; exit 0; }

WRAP='Wrap your entire output between <r> and </r> tags and put NOTHING outside them — no preamble, no explanation, no quotes, no markdown fences. Example: <r>your result here</r>'
if ! blank "$SEL"; then
  SYS="You are an inline text editor inside the user's document. They selected some text and spoke a command to transform it. Apply the command to the SELECTED TEXT and produce the replacement text, matching the surrounding style and preserving meaning unless told otherwise. $WRAP"
  INPUT="COMMAND: $CMD

SELECTED TEXT:
$SEL"
else
  SYS="You are an inline writing assistant. The user placed their cursor in a text field and spoke a request. Produce the text to insert at the cursor. $WRAP"
  INPUT="REQUEST: $CMD"
fi

OUT="$(SANELE_IN="$INPUT" bash "$HOME/.config/sanele/sanele-ai.sh" "$SYS" 2>>"$WF_LOG")"

# Extract only what's between the sentinel tags (discards any stray preamble).
RESULT="$(printf '%s' "$OUT" | /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s')"
blank "$RESULT" && RESULT="$OUT"                 # fallback if the model omitted tags
RESULT="$(printf '%s' "$RESULT" | /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//')"
blank "$RESULT" && RESULT="$SEL"                 # last resort: leave selection unchanged
printf '%s' "$RESULT"
