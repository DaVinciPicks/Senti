#!/bin/bash
# Resolve WHICH model the user is about to paste into, so prompt mode can tailor
# the prompt to that model's actual quirks.
#
#   $1 = hint (frontmost app name from Hammerspoon, e.g. "Claude", "ChatGPT", "Cursor")
#
# Prints the guidance block to inject, or nothing if there's no useful match.
# Resolution order: explicit menu-bar choice → frontmost-app match → universal only.
#
# Detection is free: the frontmost app name is a local, instant signal, so this
# costs no extra API call and no latency. The knowledge base lives in
# prompts/models/*.md; each file's frontmatter carries a `match:` regex.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

KB="${WF_MODEL_KB:-$HOME/.config/senti/prompts/models}"
HINT="${1:-}"
[ -d "$KB" ] || exit 0

# Pull one frontmatter value out of a KB file: fm <file> <key>
fm() { /usr/bin/sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1; }

# Only the `## Inject` digest goes into a live prompt. The full research sections
# in these files are human reference — injecting them cost ~4.5KB and pushed prompt
# mode from 2.7s to 9.9s, which is unusable for a dictation tool. Digests are ~900B.
# Falls back to the rules section if a file predates the digest convention.
section() {
  local d
  d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## Inject\s*\n(.*?)(?=^## |\z)/ms' "$1" 2>/dev/null \
       | /usr/bin/grep -v '^(Compact digest')"
  [ -n "${d// /}" ] || d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## Prompting rules\s*\n(.*?)(?=^## )/ms' "$1" 2>/dev/null)"
  printf '%s' "$d"
}

CHOSEN=""
PREF_FILE="${WF_TARGET_PREF:-$HOME/.cache/senti/target.pref}"
PREF="$(cat "$PREF_FILE" 2>/dev/null | tr -d '[:space:]')"

if [ -n "$PREF" ] && [ "$PREF" != "auto" ]; then
  for f in "$KB"/*.md; do
    [ -f "$f" ] || continue
    [ "$(fm "$f" family)" = "$PREF" ] && { CHOSEN="$f"; break; }
  done
elif [ -n "$HINT" ]; then
  for f in "$KB"/*.md; do
    [ -f "$f" ] || continue
    fam="$(fm "$f" family)"; [ "$fam" = "universal" ] && continue
    m="$(fm "$f" match)"; [ -z "$m" ] && continue
    if printf '%s' "$HINT" | /usr/bin/grep -qiE "$m"; then CHOSEN="$f"; break; fi
  done
fi

# Universal technique guidance always applies; model-specific stacks on top.
UNI="$KB/_techniques.md"
OUT=""
[ -f "$UNI" ] && OUT="$(section "$UNI")"

if [ -n "$CHOSEN" ]; then
  NAME="$(fm "$CHOSEN" display_name)"
  OUT="$OUT

The user is about to paste this prompt into: ${NAME:-that model}. Tailor it to that model specifically.
$(section "$CHOSEN")"
fi

printf '%s' "$OUT"
