#!/bin/bash
# Prompt-engineer mode: rough spoken idea → optimized LLM prompt.
#   $1 = the rough idea (transcribed)
#   $2 = optional hint: frontmost app name, used to detect WHICH model this
#        prompt is destined for so it can be tailored to that model.
#   Fast (default):        one call, few-shot exemplars + deconstruct-then-build.
#   Best (WF_PROMPT_BEST=1): generate N distinct candidates → judge picks/merges the best.
# Prints ONLY the optimized prompt. Falls back to the raw text on failure.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
# Spoken text arrives in SENTI_IN (never argv — see senti-ai.sh). argv/stdin remain
# as fallbacks for manual use.
RAW="${SENTI_IN:-}"
[ -z "$RAW" ] && RAW="${1:-$(cat)}"
HINT="${2:-}"
[ -z "${RAW// /}" ] && exit 0
AI="$HOME/.config/senti/senti-ai.sh"
extract_r(){ /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s'; }
trim(){ /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//'; }

# Session context: which project this window is, what it's working on, and the last few
# things said IN THIS WINDOW — so "do the same for the other one" resolves correctly when
# several terminals are open. Local only; leaves the Mac only as part of the prompt.
SESSION_CTX="$(bash "$HOME/.config/senti/senti-session.sh" recall \
                 "${SENTI_SKEY:-}" "${SENTI_SLABEL:-}" 2>>"$WF_LOG")"
[ -n "${SESSION_CTX// /}" ] && SESSION_CTX="

--- $SESSION_CTX"

# Model-aware guidance: what actually works on the model the user is about to
# paste into. Empty string if we can't tell — never a hard failure.
TARGET_GUIDE="$(bash "$HOME/.config/senti/senti-target.sh" "$HINT" 2>>"$WF_LOG")"
[ -n "${TARGET_GUIDE// /}" ] && TARGET_GUIDE="

--- Target-model guidance (apply this; it reflects how the destination model actually behaves) ---
$TARGET_GUIDE"

# The principles + few-shot exemplars are READ from prompts/prompt-craft.md, which
# senti-vision.sh reads too. Prompt mode runs through senti-vision.sh whenever Screen
# Recording is granted and through this script when it isn't, so any craft kept inline
# here would apply to only one of the two branches — which is exactly the bug that let
# every improvement miss the path that actually runs. One file, both readers.
CRAFT_FILE="${WF_PROMPT_CRAFT:-$HOME/.config/senti/prompts/prompt-craft.md}"
CRAFT=""
[ -f "$CRAFT_FILE" ] && CRAFT="$(cat "$CRAFT_FILE")"
# Fallback so a missing file degrades instead of producing an empty system prompt.
[ -z "${CRAFT// /}" ] && CRAFT="Apply: a precise expert role; an unambiguous task and end goal; only the constraints that matter; an explicit output format; as SHORT as possible while complete. Preserve every specific the user gave. Do not answer the request or add commentary."

if [ "${WF_PROMPT_BEST:-0}" = "1" ]; then
  N="${WF_PROMPT_CANDIDATES:-3}"
  CAND_SYS="You are a world-class prompt engineer. First deconstruct the intent, then produce ${N} DISTINCT candidate prompts for the rough idea, each taking a different angle (role, structure, or emphasis). ${CRAFT} Wrap EACH candidate in <c>...</c> tags and put nothing else. ${SESSION_CTX}${TARGET_GUIDE}"
  CANDS="$(SENTI_IN="$RAW" bash "$AI" "$CAND_SYS" 2>>"$WF_LOG")"
  JUDGE_SYS="You are a prompt-quality judge. Given the ROUGH IDEA and several CANDIDATE prompts, output the single best prompt for a capable LLM — you may merge the strongest elements of several. It must have a clear expert role, unambiguous task, the constraints that matter, and an explicit output format, and stay concise. Wrap your final choice in <r></r> and put nothing else.${TARGET_GUIDE}"
  # Picking and merging the strongest candidate is comparative reasoning — pay for depth
  # here even though the generation step runs at effort=none.
  RESULT="$(WF_EFFORT="${WF_JUDGE_EFFORT:-low}" SENTI_IN="ROUGH IDEA: ${RAW}

CANDIDATES:
${CANDS}" bash "$AI" "$JUDGE_SYS" 2>>"$WF_LOG" | extract_r | trim)"
  # If the judge somehow failed, fall back to the first candidate, then to raw.
  [ -z "${RESULT// /}" ] && RESULT="$(printf '%s' "$CANDS" | /usr/bin/perl -0777 -ne 'print $1 if /<c>(.*?)<\/c>/s' | trim)"
else
  GEN_SYS="You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt for a capable LLM. First silently deconstruct the intent, then build it. ${CRAFT}${SESSION_CTX}${TARGET_GUIDE}

Now transform the user rough idea below. Wrap your entire output between <r> and </r> tags and put nothing outside them."
  RESULT="$(SENTI_IN="$RAW" bash "$AI" "$GEN_SYS" 2>>"$WF_LOG" | extract_r | trim)"
fi

[ -z "${RESULT// /}" ] && RESULT="$RAW"
printf '%s' "$RESULT"
