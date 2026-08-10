#!/bin/bash
# Offline eval harness — scores prompt-mode output across fixed rough-idea cases so
# prompt-strategy changes are MEASURABLE. A/B by env, e.g.:
#   bash senti-eval.sh baseline
#   WF_PROMPT_BEST=1 bash senti-eval.sh best
# Averages accumulate in eval/history.csv for before/after comparison.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
LABEL="${1:-run}"
DIR="$HOME/.config/senti/eval"
CASES="$DIR/cases.txt"
[ -f "$CASES" ] || { echo "no cases file at $CASES" >&2; exit 1; }

printf '%-46s | score\n' "case"
total=0; n=0
while IFS= read -r idea; do
  [ -z "${idea// /}" ] && continue
  case "$idea" in \#*) continue ;; esac
  prompt="$(bash "$HOME/.config/senti/senti-prompt.sh" "$idea" 2>/dev/null)"
  score="$(bash "$HOME/.config/senti/senti-judge.sh" score "$idea" "$prompt" 2>/dev/null)"
  score="${score:-0}"
  printf '%-46.46s | %2s\n' "$idea" "$score"
  total=$((total + score)); n=$((n + 1))
done < "$CASES"
avg="$(/usr/bin/awk -v t="$total" -v n="$n" 'BEGIN{printf "%.2f", (n>0)?t/n:0}')"
mode="$([ "${WF_PROMPT_BEST:-0}" = "1" ] && echo Best || echo Fast)"
echo "──────────────────────────────────────────────"
printf 'RESULT [%s]  mode=%s  avg=%s/10  cases=%s\n' "$LABEL" "$mode" "$avg" "$n"
printf '%s,%s,%s,%s\n' "$LABEL" "$mode" "$avg" "$n" >> "$DIR/history.csv"
echo "(history → $DIR/history.csv)"
