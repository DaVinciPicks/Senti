#!/bin/bash
# Shared context assembly for BOTH prompt paths. This file exists because the two
# paths (senti-vision.sh when Screen Recording is granted, senti-prompt.sh when it
# isn't) once carried hand-duplicated copies of this logic — and every improvement
# silently applied only to the branch that didn't run. One function, both callers;
# the self-test asserts both source this file.
#
# Sourced, not executed. Helpers read their identity from env (SENTI_SLABEL /
# SENTI_SKEY / SENTI_HINT, set by senti.lua's runScript) so window titles — which
# carry project and task names — stay off argv.

# Emits the full guidance block for prompt mode: craft + vault digest + session
# memory + target-model guidance. Empty sections are skipped; never a hard failure.
senti_prompt_context() {
  local out="" craft brain sess tgt
  craft="${WF_PROMPT_CRAFT:-$HOME/.config/senti/prompts/prompt-craft.md}"
  if [ -f "$craft" ]; then
    out="

--- How to build the prompt ---
$(cat "$craft")"
  else
    # Degrade, don't blank: a missing craft file still yields the core principles.
    out="

--- How to build the prompt ---
Apply: a precise expert role; an unambiguous task and end goal; only the constraints that matter; an explicit output format; as SHORT as possible while complete. Preserve every specific the user gave. Do not answer the request or add commentary."
  fi
  brain="$(bash "$HOME/.config/senti/senti-brain.sh" 2>>"$WF_LOG")"
  [ -n "${brain// /}" ] && out="$out

--- $brain"
  sess="$(bash "$HOME/.config/senti/senti-session.sh" recall 2>>"$WF_LOG")"
  [ -n "${sess// /}" ] && out="$out

--- $sess"
  tgt="$(bash "$HOME/.config/senti/senti-target.sh" 2>>"$WF_LOG")"
  [ -n "${tgt// /}" ] && out="$out

--- Target-model guidance (apply this; it reflects how the destination model behaves) ---
$tgt"
  printf '%s' "$out"
}
