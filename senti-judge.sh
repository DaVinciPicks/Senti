#!/bin/bash
# Prompt-quality judge. Two modes:
#
#   senti-judge.sh score   <idea> <prompt>            → integer 0-10   (legacy, saturating)
#   senti-judge.sh compare <idea> <fileA> <fileB>     → A | B | TIE    (discriminating)
#
# WHY COMPARE EXISTS: absolute 0-10 scoring saturates. Measured here — gpt-5.4-mini,
# gpt-5.6-luna, gpt-5.6-terra and every reasoning_effort level all scored 8.00-8.25 on
# the same 8 cases, i.e. the scale could not tell any of them apart. Pointwise judges
# cluster in the 6-8 band and avoid extreme ratings regardless of real quality gaps, so
# a single number is close to useless for A/B work.
#
# `compare` fixes that three ways:
#   1. head-to-head instead of absolute — the judge must commit to an ordering;
#   2. each pair judged TWICE with the order swapped, and a disagreement is recorded as
#      a TIE rather than trusting either run (this is what neutralises position bias —
#      without it you mostly measure "the judge likes whichever came first");
#   3. named dimensions instead of one holistic "quality", so real differences surface.
#
# Candidates are passed as FILE PATHS and the spoken idea via SENTI_IN — never argv.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

MODE="${1:-score}"
AI="$HOME/.config/senti/senti-ai.sh"

DIMS='Judge on: (1) faithfulness — every specific in the rough idea survives, nothing invented;
(2) task clarity — an unambiguous instruction and end goal;
(3) fitness for the destination model — uses that model'"'"'s conventions rather than generic filler;
(4) concision — no padding, no restated constraints, no ceremony;
(5) output contract — the response shape is actually specified.'

case "$MODE" in
  score)
    IDEA="${SENTI_IN:-${2:-}}"
    PROMPT="${3:-}"
    [ -z "${PROMPT// /}" ] && { echo 0; exit 0; }
    SYS="You are a strict prompt-quality judge. Score the CANDIDATE prompt (generated from the ROUGH IDEA) from 0 to 10. $DIMS Grade on a demanding curve: reserve 9-10 ONLY for a prompt with nothing meaningful to improve; a solid, usable prompt with a minor gap is 7-8; missing role/task/format or noticeably vague is 4-6; broken or off-intent is 0-3. Output ONLY the integer 0-10 — no words, no punctuation."
    OUT="$(WF_OPERATING_LAYER=0 WF_EFFORT="${WF_JUDGE_EFFORT:-low}" \
           SENTI_IN="ROUGH IDEA: $IDEA

CANDIDATE PROMPT:
$PROMPT" bash "$AI" "$SYS" 2>>"$WF_LOG")"
    echo "$OUT" | /usr/bin/grep -oE '10|[0-9]' | head -1
    ;;

  compare)
    IDEA="${SENTI_IN:-${2:-}}"
    FA="${3:-}"; FB="${4:-}"
    [ -f "$FA" ] && [ -f "$FB" ] || { echo TIE; exit 0; }
    A="$(cat "$FA")"; B="$(cat "$FB")"
    [ -z "${A// /}" ] && { echo B; exit 0; }
    [ -z "${B// /}" ] && { echo A; exit 0; }

    SYS="You are a strict prompt-quality judge comparing two candidate prompts written from the same rough spoken idea. $DIMS
Decide which ONE a capable person would actually paste. Be decisive — only say TIE if they are genuinely indistinguishable on every dimension above.
Answer with exactly one character inside the tags: <r>A</r> or <r>B</r> or <r>TIE</r>. Nothing else."

    ask() {  # ask <first> <second> ; returns which LABEL won, mapped back to A/B
      local first="$1" second="$2" firstlabel="$3" secondlabel="$4" out v
      out="$(WF_OPERATING_LAYER=0 WF_EFFORT="${WF_JUDGE_EFFORT:-low}" \
             SENTI_IN="ROUGH IDEA: $IDEA

CANDIDATE A:
$first

CANDIDATE B:
$second" bash "$AI" "$SYS" 2>>"$WF_LOG")"
      v="$(printf '%s' "$out" | /usr/bin/perl -0777 -ne 'print $1 if /<r>\s*(A|B|TIE)\s*<\/r>/si' | /usr/bin/tr 'a-z' 'A-Z')"
      case "$v" in
        A) printf '%s' "$firstlabel" ;;
        B) printf '%s' "$secondlabel" ;;
        *) printf 'TIE' ;;
      esac
    }

    # Same pair, both orders. Agreement = a real verdict; disagreement = position bias.
    R1="$(ask "$A" "$B" A B)"
    R2="$(ask "$B" "$A" B A)"
    if [ "$R1" = "$R2" ]; then echo "$R1"; else echo TIE; fi
    ;;

  *) echo "usage: senti-judge.sh {score|compare} ..." >&2; exit 1 ;;
esac
