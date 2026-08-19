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
source "$HOME/.config/sanele/config.sh"

KB="${WF_MODEL_KB:-$HOME/.config/sanele/prompts/models}"
# App-name hint via env first (SANELE_HINT from runScript); argv is a manual fallback.
HINT="${1:-${SANELE_HINT:-}}"
[ -d "$KB" ] || exit 0

# An app NAME frequently says nothing about the destination model — the window TITLE
# does. "Google Chrome" is whatever tab is open; "Terminal" is very often Claude Code,
# whose title literally ends in "claude". So resolve in TWO steps: the app name first
# (right when the app IS the product — the Claude or ChatGPT desktop app), then the
# window title as a fallback.
#
# This replaces an allowlist that swapped in the title for browsers only, which left
# the most-used destination on this machine — a terminal running Claude Code — falling
# through to generic universal guidance. Measured before the change: hint "Terminal"
# → 836B universal digest; hint "Claude" → 974B Anthropic-specific digest.
#
# INVARIANT (asserted by sanele-selftest.sh): a `match:` regex must only ever match a
# MODEL or PRODUCT name, never a browser or terminal app name. Were one to match
# "Terminal" or "Safari", step 1 would hijack every lookup made from that app. The
# self-test pins this so a future KB edit can't silently break it.
TITLE="${SANELE_SLABEL:-}"

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
PREF_FILE="${WF_TARGET_PREF:-$HOME/.cache/sanele/target.pref}"
PREF="$(cat "$PREF_FILE" 2>/dev/null | tr -d '[:space:]')"

if [ -n "$PREF" ] && [ "$PREF" != "auto" ]; then
  for f in "$KB"/*.md; do
    [ -f "$f" ] || continue
    [ "$(fm "$f" family)" = "$PREF" ] && { CHOSEN="$f"; break; }
  done
elif [ -n "$HINT" ] || [ -n "$TITLE" ]; then
  # App name first, window title second. `break 2` leaves both loops on the first hit.
  for probe in "$HINT" "$TITLE"; do
    [ -n "$probe" ] || continue
    for f in "$KB"/*.md; do
      [ -f "$f" ] || continue
      fam="$(fm "$f" family)"; [ "$fam" = "universal" ] && continue
      m="$(fm "$f" match)"; [ -z "$m" ] && continue
      if printf '%s' "$probe" | /usr/bin/grep -qiE "$m"; then CHOSEN="$f"; break 2; fi
    done
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
