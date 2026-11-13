#!/bin/bash
# Prompt-quality judge. Two modes:
#
#   senti-judge.sh score   "" <promptFile>            → integer 0-10   (legacy, saturating)
#   senti-judge.sh compare "" <fileA> <fileB>         → A | B | TIE    (discriminating)
#
# The spoken idea arrives in SENTI_IN and the destination (what the prompt will be pasted
# into, e.g. "Claude Code, an agentic coding tool in a terminal") in SENTI_DEST. Prompts
# arrive as FILE PATHS. Nothing user-derived ever rides argv.
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
# The judge is PINNED (openai gpt-6-luna at effort low unless SENTI_JUDGE_PROVIDER /
# SENTI_JUDGE_MODEL say otherwise), so a result stays comparable whichever provider wrote
# the prompts. A failed judge call prints ERR and exits with senti-ai.sh's code: a broken
# judge must never be counted as a TIE.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

MODE="${1:-score}"
AI="$HOME/.config/senti/senti-ai.sh"
IDEA="${SENTI_IN:-}"
DEST="${SENTI_DEST:-}"
JP="${SENTI_JUDGE_PROVIDER:-openai}"
JM="${SENTI_JUDGE_MODEL:-gpt-6-luna}"
JE="${WF_JUDGE_EFFORT:-low}"

DIMS='Judge on: (1) faithfulness — every specific in the rough idea survives, nothing invented;
(2) task clarity — an unambiguous instruction and end goal;
(3) fitness for the destination model — uses that model'"'"'s conventions rather than generic filler;
(4) concision — no padding, no restated constraints, no ceremony;
(5) output contract — the response shape is actually specified.'
DESTLINE=""
[ -n "$DEST" ] && DESTLINE="DESTINATION (where the prompt will be pasted): $DEST

"

judge_call() {   # judge_call <system> <user> → model text; returns senti-ai.sh's exit code
  SENTI_PROVIDER="$JP" SENTI_MODEL="$JM" SENTI_EFFORT="$JE" SENTI_MODE=judge \
  WF_OPERATING_LAYER=0 SENTI_SYS="$1" SENTI_IN="$2" bash "$AI" 2>>"$WF_LOG"
}

case "$MODE" in
  score)
    PF="${3:-}"
    [ -f "$PF" ] || { echo "usage: SENTI_IN=<idea> senti-judge.sh score \"\" <promptFile>" >&2; exit 2; }
    PROMPT="$(cat "$PF")"
    case "$PROMPT" in *[![:space:]]*) ;; *) echo 0; exit 0 ;; esac
    SYS="You are a strict prompt-quality judge. Score the CANDIDATE prompt (generated from the ROUGH IDEA) from 0 to 10. $DIMS Grade on a demanding curve: reserve 9-10 ONLY for a prompt with nothing meaningful to improve; a solid, usable prompt with a minor gap is 7-8; missing role/task/format or noticeably vague is 4-6; broken or off-intent is 0-3. Output ONLY the integer 0-10 — no words, no punctuation."
    OUT="$(judge_call "$SYS" "${DESTLINE}ROUGH IDEA: $IDEA

CANDIDATE PROMPT:
$PROMPT")"
    RC=$?
    [ "$RC" -eq 0 ] || { echo ERR; exit "$RC"; }
    V="$(printf '%s' "$OUT" | /usr/bin/grep -oE '10|[0-9]' | head -1)"
    [ -n "$V" ] || { echo ERR; exit 17; }
    echo "$V"
    ;;

  compare)
    FA="${3:-}"; FB="${4:-}"
    [ -f "$FA" ] && [ -f "$FB" ] || { echo "usage: SENTI_IN=<idea> senti-judge.sh compare \"\" <fileA> <fileB>" >&2; exit 2; }
    A="$(cat "$FA")"; B="$(cat "$FB")"
    case "$A" in *[![:space:]]*) ;; *) echo B; exit 0 ;; esac
    case "$B" in *[![:space:]]*) ;; *) echo A; exit 0 ;; esac

    SYS="You are a strict prompt-quality judge comparing two candidate prompts written from the same rough spoken idea. $DIMS
Decide which ONE a capable person would actually paste into the destination. Be decisive — only say TIE if they are genuinely indistinguishable on every dimension above.
Answer with exactly one character inside the tags: <r>A</r> or <r>B</r> or <r>TIE</r>. Nothing else."

    ask() {  # ask <first> <second> <firstlabel> <secondlabel> → winning label, A/B/TIE
      local out v rc
      out="$(judge_call "$SYS" "${DESTLINE}ROUGH IDEA: $IDEA

CANDIDATE A:
$1

CANDIDATE B:
$2")"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      v="$(printf '%s' "$out" | /usr/bin/perl -0777 -ne 'print $1 if /<r>\s*(A|B|TIE)\s*<\/r>/si' | /usr/bin/tr 'a-z' 'A-Z')"
      case "$v" in
        A) printf '%s' "$3" ;;
        B) printf '%s' "$4" ;;
        *) printf 'TIE' ;;
      esac
    }

    # Same pair, both orders. Agreement = a real verdict; disagreement = position bias.
    R1="$(ask "$A" "$B" A B)" || { RC=$?; echo ERR; exit "$RC"; }
    R2="$(ask "$B" "$A" B A)" || { RC=$?; echo ERR; exit "$RC"; }
    if [ "$R1" = "$R2" ]; then echo "$R1"; else echo TIE; fi
    ;;

  *) echo "usage: senti-judge.sh {score|compare} ..." >&2; exit 2 ;;
esac
