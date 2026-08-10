#!/bin/bash
# Prompt-engineer mode: rough spoken idea → optimized LLM prompt. One call.
#   $1 = the rough idea (fallback; normally arrives via SENTI_IN)
#   $2 = optional hint: frontmost app name → which model the prompt is destined for
# Prints ONLY the optimized prompt. Falls back to the raw text on failure.
#
# NOTE: this is the FALLBACK path — live prompt mode routes through senti-vision.sh
# whenever Screen Recording is granted (senti.lua). Keep the two in parity; the
# self-test asserts it. Best mode (N candidates → judge) was deleted 2026-08-09:
# it was unreachable from the live path, was never once measured better than one
# call, and spent 2x latency betting on sampling variance instead of context quality.
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

# Second brain: a capped digest of the user's own vault note for this project.
# See senti-brain.sh for the privacy model (allowlist, cap, log, kill switch).
BRAIN_CTX="$(bash "$HOME/.config/senti/senti-brain.sh" "${SENTI_SLABEL:-}" 2>>"$WF_LOG")"
[ -n "${BRAIN_CTX// /}" ] && BRAIN_CTX="

--- $BRAIN_CTX"

# Model-aware guidance: what actually works on the model the user is about to
# paste into. Empty string if we can't tell — never a hard failure.
TARGET_GUIDE="$(bash "$HOME/.config/senti/senti-target.sh" "$HINT" 2>>"$WF_LOG")"
[ -n "${TARGET_GUIDE// /}" ] && TARGET_GUIDE="

--- Target-model guidance (apply this; it reflects how the destination model actually behaves) ---
$TARGET_GUIDE"

# The principles + few-shot exemplars are READ from prompts/prompt-craft.md, which
# senti-vision.sh reads too — one file, both paths, so they can't drift.
CRAFT_FILE="${WF_PROMPT_CRAFT:-$HOME/.config/senti/prompts/prompt-craft.md}"
CRAFT=""
[ -f "$CRAFT_FILE" ] && CRAFT="$(cat "$CRAFT_FILE")"
# Fallback so a missing file degrades instead of producing an empty system prompt.
[ -z "${CRAFT// /}" ] && CRAFT="Apply: a precise expert role; an unambiguous task and end goal; only the constraints that matter; an explicit output format; as SHORT as possible while complete. Preserve every specific the user gave. Do not answer the request or add commentary."

GEN_SYS="You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt for a capable LLM. First silently deconstruct the intent, then build it. ${CRAFT}${BRAIN_CTX}${SESSION_CTX}${TARGET_GUIDE}

Now transform the user rough idea below. The examples above show only the content of a good prompt — your actual reply must still be wrapped: put your entire output between <r> and </r> tags and nothing outside them."
# GEN_SYS embeds session transcripts + the vault digest → it goes via env (SENTI_SYS),
# never argv. See senti-ai.sh.
OUT="$(SENTI_SYS="$GEN_SYS" SENTI_IN="$RAW" bash "$AI" 2>>"$WF_LOG")"
RESULT="$(printf '%s' "$OUT" | extract_r | trim)"
# Degrade in order: tagged answer → untagged answer (model ignored the sentinel but
# still optimized) → raw transcript. Previously a missing tag silently pasted the
# user's rambling raw speech as if it were the optimized prompt.
[ -z "${RESULT// /}" ] && RESULT="$(printf '%s' "$OUT" | trim)"
[ -z "${RESULT// /}" ] && RESULT="$RAW"
printf '%s' "$RESULT"
