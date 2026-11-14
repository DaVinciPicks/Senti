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
# App-name hint via env first (SENTI_HINT from runScript); argv is a manual fallback.
HINT="${1:-${SENTI_HINT:-}}"
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
# INVARIANT (asserted by senti-selftest.sh): a `match:` regex must only ever match a
# MODEL or PRODUCT name, never a browser or terminal app name. Were one to match
# "Terminal" or "Safari", step 1 would hijack every lookup made from that app. The
# self-test pins this so a future KB edit can't silently break it.
TITLE="${SENTI_SLABEL:-}"

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

# ── Exact model, not just the family ────────────────────────────────────────────────
# The window title carries the project and the task but NOT the model — what looks like
# a model name in a Claude Code terminal is its statusline, rendered inside the pane and
# invisible to us. Claude Code does however write the active model into its own session
# transcript, which is a local file we can read for free:
#     ~/.claude/projects/<cwd-slug>/<session>.jsonl  →  "model":"claude-opus-5"
# Newest transcript in the matching project dir wins, which is the session the user is
# actually in. No API call, no screenshot, no extra latency budget.
#
# This only resolves for Claude Code. The Claude desktop app, ChatGPT and everything else
# have no such file and fall through to family-level guidance, exactly as before.
cc_model() {
  local proj base dir newest
  proj="$(printf '%s' "${TITLE:-}" | /usr/bin/sed 's/ —.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$proj" ] || return 0
  base="$HOME/.claude/projects"; [ -d "$base" ] || return 0
  dir="$(/bin/ls -1dt "$base"/*"$proj" 2>/dev/null | head -1)"
  [ -n "$dir" ] || return 0
  newest="$(/bin/ls -1t "$dir"/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || return 0
  # Only the tail: transcripts reach tens of MB and the newest model line is at the end.
  /usr/bin/tail -c 120000 "$newest" 2>/dev/null \
    | /usr/bin/grep -oE '"model":"claude-[a-z0-9.-]+"' | tail -1 \
    | /usr/bin/sed 's/.*"model":"//; s/"$//'
}

# Pull a per-model delta out of the KB file: "## Model: <id>" ... up to the next "## ".
model_section() {
  /usr/bin/perl -0777 -ne "print \$1 if /^## Model: \Q$2\E\s*\n(.*?)(?=^## |\z)/ms" "$1" 2>/dev/null
}

# Universal technique guidance always applies; model-specific stacks on top.
UNI="$KB/_techniques.md"
OUT=""
[ -f "$UNI" ] && OUT="$(section "$UNI")"

if [ -n "$CHOSEN" ]; then
  NAME="$(fm "$CHOSEN" display_name)"
  MODEL="$(cc_model)"
  DELTA=""
  [ -n "$MODEL" ] && DELTA="$(model_section "$CHOSEN" "$MODEL")"
  if [ -n "${DELTA// /}" ]; then
    NAME="$MODEL"
    echo "$(date '+%F %T') target: resolved exact model '$MODEL'" >>"$WF_LOG" 2>/dev/null
  elif [ -n "$MODEL" ] && [ "${WF_KB_FALLBACK:-1}" = "1" ]; then
    # Nearest older id: a model newer than the KB (claude-opus-5-5 before its section was
    # written) gets its predecessor's section (claude-opus-5) rather than nothing, and the
    # log says so, so a stale KB is visible. Drop one trailing "-part" at a time, never
    # below family-plus-one-part (claude-opus), which would match a different generation.
    # First the nearest older SIBLING: claude-opus-5-7 takes claude-opus-5-5, the highest
    # "<prefix>-<n>" section with n below 7, before trimming to claude-opus-5. The prefix
    # must keep family-plus-one-part, so claude-opus-6 never borrows claude-opus-5, and a
    # dated snapshot (claude-sonnet-5-20260101) skips this step so it never takes a newer -5-5.
    OLDER=""; DELTA=""
    case "$MODEL" in
      *-*-*-*) case "${MODEL##*-}" in ''|*[!0-9]*|???*) ;; *)   # a 1-2 digit minor, never a date
        OLDER="$(/usr/bin/perl -ne 'BEGIN { ($p, $n) = splice(@ARGV, 0, 2); $b = -1 }
          $b = $1 if /^## Model: \Q$p\E-(\d+)\s*$/ && $1 < $n && $1 > $b;
          END { print "$p-$b" if $b >= 0 }' "${MODEL%-*}" "${MODEL##*-}" "$CHOSEN" 2>/dev/null)"
        [ -n "$OLDER" ] && DELTA="$(model_section "$CHOSEN" "$OLDER")" ;;
      esac ;;
    esac
    if [ -z "${DELTA// /}" ]; then
      OLDER="$MODEL"
      while :; do
        case "$OLDER" in *-*-*) OLDER="${OLDER%-*}" ;; *) OLDER=""; break ;; esac
        case "$OLDER" in *-*-*) ;; *) OLDER=""; break ;; esac
        DELTA="$(model_section "$CHOSEN" "$OLDER")"
        [ -n "${DELTA// /}" ] && break
      done
    fi
    if [ -n "$OLDER" ] && [ -n "${DELTA// /}" ]; then
      NAME="$MODEL"
      echo "$(date '+%F %T') target: fallback model '$OLDER' for '$MODEL'" >>"$WF_LOG" 2>/dev/null
    else
      DELTA=""
    fi
  fi
  OUT="$OUT

The user is about to paste this prompt into: ${NAME:-that model}. Tailor it to that model specifically.
$(section "$CHOSEN")${DELTA:+
$DELTA}"
fi

printf '%s' "$OUT"
