#!/bin/bash
# Prompt-quality judge — scores a generated prompt 0-10. Used by the offline eval
# harness and (optionally) best mode.
#   $1 = the rough idea   $2 = the candidate prompt
# Prints a single integer 0-10.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
IDEA="${1:-}"; PROMPT="${2:-}"
[ -z "${PROMPT// /}" ] && { echo 0; exit 0; }

SYS='You are a strict prompt-quality judge. Score the CANDIDATE prompt (generated from the ROUGH IDEA) from 0 to 10 on faithfulness to intent, a clear expert role + unambiguous task, the constraints that matter, an explicit output format, and conciseness. Grade on a demanding curve: reserve 9-10 ONLY for a prompt with nothing meaningful to improve; a solid, usable prompt with a minor gap is 7-8; missing role/task/format or noticeably vague is 4-6; broken or off-intent is 0-3. Output ONLY the integer 0-10 — no words, no punctuation.'
IN="ROUGH IDEA: $IDEA

CANDIDATE PROMPT:
$PROMPT"
# Judge without the operating layer so it returns only a bare number. Scoring is a
# genuine comparative-reasoning task, so it gets more effort than the rewrite path.
OUT="$(WF_OPERATING_LAYER=0 WF_EFFORT="${WF_JUDGE_EFFORT:-low}" \
       bash "$HOME/.config/senti/senti-ai.sh" "$SYS" "$IN" 2>>"$WF_LOG")"
echo "$OUT" | grep -oE '10|[0-9]' | head -1
