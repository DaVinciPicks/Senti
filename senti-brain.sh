#!/bin/bash
# Second-brain bridge: pull a SMALL digest of the user's own notes for the project
# they're working in, so prompt mode knows what the project actually is.
#
#   senti-brain.sh <project-hint>     # e.g. "senti", "davincibets_main"
#
# Prints a capped digest, or nothing. Sources, in order:
#   1. an explicit mapping in brain-map.txt (project|path/to/note.md, vault-relative)
#   2. an allowlisted dir whose name matches the project → its <dir>/<dir>.md
#      (or the single .md inside, if the convention isn't followed)
#
# PRIVACY MODEL — read before widening anything here:
#   - Whatever this prints is injected into prompt mode and therefore RIDES THE API
#     CALL to OpenAI. That is the entire point, and also the entire risk.
#   - So: only allowlisted dirs are ever searched (default: Efforts/Active and
#     Atlas/DaVinci Bets — never People/, never Calendar/, never the vault root).
#   - Digest is hard-capped (WF_BRAIN_MAX chars). A note can control exactly what
#     Senti sees by adding a "## Senti" section — then ONLY that section is used.
#   - Every injection is logged to senti.log by note name, so there's a record of
#     what left the machine. Kill switch: WF_BRAIN=0.
#   - Verbatim dictation never touches this script.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

[ "${WF_BRAIN:-1}" = "1" ] || exit 0
VAULT="${WF_VAULT:-$HOME/Documents/Obsidian Vault}"
[ -d "$VAULT" ] || exit 0
MAX="${WF_BRAIN_MAX:-700}"
MAP="${WF_BRAIN_MAP:-$HOME/.config/senti/brain-map.txt}"
CACHEDIR="$HOME/.cache/senti/brain"
mkdir -p "$CACHEDIR" 2>/dev/null; chmod 700 "$CACHEDIR" 2>/dev/null

# ── refresh mode (background worker) ─────────────────────────────────────
#   senti-brain.sh refresh <abs-note-path> <cache-key>
# One cheap luna call (~$0.001) compresses the note into a digest for NEXT time.
# Runs lazily: only when a stale project is actually used — no cron, no scheduler,
# and projects you never touch are never sent anywhere.
if [ "${1:-}" = "refresh" ]; then
  RNOTE="${2:-}"; RKEY="${3:-}"
  [ -f "$RNOTE" ] && [ -n "$RKEY" ] || exit 0
  BODY="$(/usr/bin/perl -0777 -pe 's/\A---\n.*?\n---\n//s' "$RNOTE" | head -c 24000)"
  SYS="Compress this project note into at most 120 words of plain text: what the project IS, the stack, the current focus, hard constraints, and any naming conventions. Facts only, no headings, no preamble — this becomes standing context for an assistant writing prompts about the project."
  OUT="$(WF_OPERATING_LAYER=0 SENTI_IN="$BODY" \
         bash "$HOME/.config/senti/senti-ai.sh" "$SYS" 2>>"$WF_LOG")"
  if [ -n "${OUT// /}" ]; then
    T="$(mktemp "$CACHEDIR/.tmp.XXXXXX")" && printf '%s' "$OUT" > "$T" \
      && chmod 600 "$T" && mv "$T" "$CACHEDIR/$RKEY.md"
    echo "$(date '+%H:%M:%S') brain: refreshed digest '$RKEY' ($(printf '%s' "$OUT" | wc -c | tr -d ' ') chars)" >> "$WF_LOG"
  fi
  rm -f "$CACHEDIR/.refreshing.$RKEY"
  exit 0
fi

HINT="${1:-}"
[ -z "${HINT// /}" ] && exit 0
# Callers may pass the full window title — the project is its first field.
HINT="${HINT%% — *}"

norm() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cd 'a-z0-9'; }
NH="$(norm "$HINT")"
[ "${#NH}" -lt 3 ] && exit 0   # too short to match anything safely

NOTE=""

# 1. Explicit map wins (format: project|vault-relative/path.md ; # comments allowed).
if [ -f "$MAP" ]; then
  while IFS='|' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    NK="$(norm "$k")"
    if [ -n "$NK" ] && { case "$NH" in *"$NK"*) true ;; *) case "$NK" in *"$NH"*) true ;; *) false ;; esac ;; esac }; then
      [ -f "$VAULT/$v" ] && NOTE="$VAULT/$v" && break
    fi
  done < "$MAP"
fi

# 2. Allowlisted dirs, matched by normalized name (either contains the other).
if [ -z "$NOTE" ]; then
  # Newline-separated because the vault path contains spaces.
  DIRS="${WF_BRAIN_DIRS:-Efforts/Active
Atlas/DaVinci Bets}"
  while IFS= read -r rel; do
    [ -d "$VAULT/$rel" ] || continue
    for d in "$VAULT/$rel"/*/; do
      [ -d "$d" ] || continue
      base="$(basename "$d")"
      NB="$(norm "$base")"
      [ "${#NB}" -lt 3 ] && continue
      case "$NH" in *"$NB"*) M=1 ;; *) case "$NB" in *"$NH"*) M=1 ;; *) M=0 ;; esac ;; esac
      if [ "$M" = "1" ]; then
        if [ -f "$d$base.md" ]; then NOTE="$d$base.md"
        else
          # Convention not followed — accept a single unambiguous note, else skip.
          only="$(/usr/bin/find "$d" -maxdepth 1 -name '*.md' | head -2)"
          [ "$(printf '%s\n' "$only" | /usr/bin/grep -c .)" = "1" ] && NOTE="$only"
        fi
        [ -n "$NOTE" ] && break 2
      fi
    done
  done <<EOF
$DIRS
EOF
fi

[ -n "$NOTE" ] && [ -f "$NOTE" ] || exit 0

# Cached LLM digest first: fresher than 24h AND not older than the note itself
# (an edited note invalidates its digest). Falls through to raw extraction below.
KEY="$(norm "$(basename "$NOTE" .md)")"
CACHE="$CACHEDIR/$KEY.md"
if [ -s "$CACHE" ] && [ -n "$(/usr/bin/find "$CACHE" -mmin -1440 -newer "$NOTE" 2>/dev/null)" ]; then
  DIGEST="$(head -c "$MAX" "$CACHE")"
  echo "$(date '+%H:%M:%S') brain: injected cached digest '$KEY' for hint '$HINT'" >> "$WF_LOG"
  printf 'Project knowledge from the user'"'"'s own notes (their vault is ground truth — trust it over guesses):\n%s\n' "$DIGEST"
  exit 0
fi
# Stale or missing → serve the raw extract NOW (zero added latency) and refresh in
# the background for next time. `&` + parent exit orphans the worker safely.
# The lock marker stops rapid consecutive dictations from stampeding parallel
# refreshes of the same note; a stuck lock self-expires after 3 minutes.
if [ "${WF_BRAIN_REFRESH:-1}" = "1" ]; then
  LOCK="$CACHEDIR/.refreshing.$KEY"
  if [ -z "$(/usr/bin/find "$LOCK" -mmin -3 2>/dev/null)" ]; then
    : > "$LOCK"
    ( bash "$HOME/.config/senti/senti-brain.sh" refresh "$NOTE" "$KEY" >/dev/null 2>&1 & )
  fi
fi

# Digest, in order of preference:
#   "## Senti" section  → the note author's explicit choice of what Senti may see
#   "## For future Claude" → written for AI consumption already
#   else                → first body lines after frontmatter
DIGEST="$(/usr/bin/perl -0777 -ne 'print $1 if /^## Senti\s*\n(.*?)(?=^## |\z)/ms' "$NOTE")"
[ -z "${DIGEST// /}" ] && DIGEST="$(/usr/bin/perl -0777 -ne 'print $1 if /^## For future Claude\s*\n(.*?)(?=^## |\z)/ms' "$NOTE")"
if [ -z "${DIGEST// /}" ]; then
  DIGEST="$(/usr/bin/perl -0777 -pe 's/\A---\n.*?\n---\n//s' "$NOTE" | /usr/bin/grep -v '^#' | /usr/bin/grep -v '^\s*$' | head -10)"
fi
# Strip wiki-link noise ([[x|y]] → y, [[x]] → x) and inline field syntax, then cap.
DIGEST="$(printf '%s' "$DIGEST" \
  | /usr/bin/perl -pe 's/\[\[[^\]|]*\|([^\]]*)\]\]/$1/g; s/\[\[([^\]]*)\]\]/$1/g' \
  | cut -c1-100000 | head -c "$MAX")"
[ -z "${DIGEST// /}" ] && exit 0

echo "$(date '+%H:%M:%S') brain: injected '$(basename "$NOTE")' ($(printf '%s' "$DIGEST" | wc -c | tr -d ' ') chars) for hint '$HINT'" >> "$WF_LOG"
printf 'Project knowledge from the user'"'"'s own notes (their vault is ground truth — trust it over guesses):\n%s\n' "$DIGEST"
