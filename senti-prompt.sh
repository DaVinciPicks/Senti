#!/bin/bash
# Prompt-engineer mode: rough spoken idea → optimized LLM prompt.
#   Fast (default):        one call, few-shot exemplars + deconstruct-then-build.
#   Best (WF_PROMPT_BEST=1): generate N distinct candidates → judge picks/merges the best.
# Prints ONLY the optimized prompt. Falls back to the raw text on failure.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
RAW="${1:-$(cat)}"
[ -z "${RAW// /}" ] && exit 0
AI="$HOME/.config/senti/senti-ai.sh"
extract_r(){ /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s'; }
trim(){ /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//'; }

PRINCIPLES="Apply: (1) a precise expert role; (2) the task and end goal, unambiguous; (3) only the context and constraints that matter; (4) the desired output format; (5) for complex work, tell the model to work in stages; (6) as SHORT as possible while complete. Preserve every specific the user gave. Do not answer the request or add commentary."

FEWSHOT="Examples of the transformation:
ROUGH: help me email my landlord about my broken heater
PROMPT: <r>You are a firm, professional tenant advocate. Draft a concise email to my landlord reporting that my apartment heater has stopped working. State the issue and its impact, request repair within a specific reasonable timeframe, note the obligation to maintain habitable conditions, and stay polite but firm. Output only the email.</r>

ROUGH: make me something to analyze my csv sales data and find trends
PROMPT: <r>You are a senior data analyst. I will provide a CSV of sales data. Summarize its structure, then identify the top 3-5 trends (growth/decline, seasonality, outliers, best/worst performers) with the specific numbers supporting each, and one recommended action per trend. If no file is attached, ask for it. Output a short structured report; no code unless I ask.</r>"

if [ "${WF_PROMPT_BEST:-0}" = "1" ]; then
  N="${WF_PROMPT_CANDIDATES:-3}"
  CAND_SYS="You are a world-class prompt engineer. First deconstruct the intent, then produce ${N} DISTINCT candidate prompts for the rough idea, each taking a different angle (role, structure, or emphasis). ${PRINCIPLES} Wrap EACH candidate in <c>...</c> tags and put nothing else. ${FEWSHOT}"
  CANDS="$(bash "$AI" "$CAND_SYS" "$RAW" 2>>"$WF_LOG")"
  JUDGE_SYS="You are a prompt-quality judge. Given the ROUGH IDEA and several CANDIDATE prompts, output the single best prompt for a capable LLM — you may merge the strongest elements of several. It must have a clear expert role, unambiguous task, the constraints that matter, and an explicit output format, and stay concise. Wrap your final choice in <r></r> and put nothing else."
  RESULT="$(bash "$AI" "$JUDGE_SYS" "ROUGH IDEA: ${RAW}

CANDIDATES:
${CANDS}" 2>>"$WF_LOG" | extract_r | trim)"
  # If the judge somehow failed, fall back to the first candidate, then to raw.
  [ -z "${RESULT// /}" ] && RESULT="$(printf '%s' "$CANDS" | /usr/bin/perl -0777 -ne 'print $1 if /<c>(.*?)<\/c>/s' | trim)"
else
  GEN_SYS="You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt for a capable LLM. First silently deconstruct the intent, then build it. ${PRINCIPLES} ${FEWSHOT}

Now transform the user rough idea below. Wrap your entire output between <r> and </r> tags and put nothing outside them."
  RESULT="$(bash "$AI" "$GEN_SYS" "$RAW" 2>>"$WF_LOG" | extract_r | trim)"
fi

[ -z "${RESULT// /}" ] && RESULT="$RAW"
printf '%s' "$RESULT"
