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
#   - So: only the folders listed in WF_BRAIN_DIRS are ever searched. There is no
#     default list, and the whole bridge is off unless WF_BRAIN=1.
#   - Digest is hard-capped (WF_BRAIN_MAX chars). A note can control exactly what
#     Senti sees by adding a "## Senti" section — then ONLY that section is used.
#   - Every injection is logged to senti.log by note name, so there's a record of
#     what left the machine. Kill switch: WF_BRAIN=0.
#   - Verbatim dictation never touches this script.
set -uo pipefail
# Blank test that stays O(n) on bash 3.2 (${VAR// /} is quadratic there: 8 KB took 4.8s).
blank() { case "$1" in *[![:space:]]*) return 1 ;; *) return 0 ;; esac; }
source "$HOME/.config/senti/config.sh"

[ "${WF_BRAIN:-0}" = "1" ] || exit 0   # opt-in: off unless config.sh sets WF_BRAIN=1
VAULT="${WF_VAULT:-$HOME/Documents/Obsidian Vault}"
[ -d "$VAULT" ] || exit 0
MAX="${WF_BRAIN_MAX:-700}"
MAP="${WF_BRAIN_MAP:-$HOME/.config/senti/brain-map.txt}"
CACHEDIR="$HOME/.cache/senti/brain"
mkdir -p "$CACHEDIR" 2>/dev/null; chmod 700 "$CACHEDIR" 2>/dev/null

# Extract the shippable digest from a note, in order of preference:
#   "## Senti" section       → the note author's explicit choice of what Senti may see
#                              (legacy "## Sanele" too: the heading is a privacy control,
#                              and a rename that misses one note must not fall through
#                              to the broader fallbacks below — it did once, 2026-08-19)
#   "## For future Claude"   → already written for AI consumption
#   else                     → first body lines after the frontmatter
# Wiki-link noise stripped, hard-capped at WF_BRAIN_MAX. This is the ONE gate that keeps
# private note content from leaving the Mac — BOTH the read path and the background
# refresh upload must go through it (the refresh once sent 24KB of raw body, bypassing
# every control this function enforces).
brain_digest() {
  local f="$1" d
  d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## (?:Senti|Sanele)\s*\n(.*?)(?=^## |\z)/ms' "$f")"
  blank "$d" && d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## For future Claude\s*\n(.*?)(?=^## |\z)/ms' "$f")"
  blank "$d" && d="$(/usr/bin/perl -0777 -pe 's/\A---\n.*?\n---\n//s' "$f" | /usr/bin/grep -v '^#' | /usr/bin/grep -v '^\s*$' | head -10)"
  printf '%s' "$d" \
    | /usr/bin/perl -pe 's/\[\[[^\]|]*\|([^\]]*)\]\]/$1/g; s/\[\[([^\]]*)\]\]/$1/g' \
    | cut -c1-100000 | head -c "$MAX"
}

# ── refresh mode (background worker) ─────────────────────────────────────
#   senti-brain.sh refresh <abs-note-path> <cache-key>
# One cheap luna call (~$0.001) compresses the note into a digest for NEXT time.
# Runs lazily: only when a stale project is actually used — no cron, no scheduler,
# and projects you never touch are never sent anywhere.
if [ "${1:-}" = "refresh" ]; then
  RNOTE="${SENTI_RNOTE:-${2:-}}"; RKEY="${3:-}"
  [ -f "$RNOTE" ] && [ -n "$RKEY" ] || exit 0
  # Feed the LLM the SAME gated digest the read path would inject — not the raw note.
  # This respects the ## Senti section choice and the WF_BRAIN_MAX cap; a note without
  # an allowed section still only exposes its capped first lines.
  BODY="$(brain_digest "$RNOTE")"
  blank "$BODY" && { rm -f "$CACHEDIR/.refreshing.$RKEY"; exit 0; }
  SYS="Compress this project note into at most 120 words of plain text: what the project IS, the stack, the current focus, hard constraints, and any naming conventions. Facts only, no headings, no preamble — this becomes standing context for an assistant writing prompts about the project."
  OUT="$(WF_OPERATING_LAYER=0 SENTI_IN="$BODY" \
         bash "$HOME/.config/senti/senti-ai.sh" "$SYS" 2>>"$WF_LOG")"
  if ! blank "$OUT"; then
    T="$(mktemp "$CACHEDIR/.tmp.XXXXXX")" && printf '%s' "$OUT" > "$T" \
      && chmod 600 "$T" && mv "$T" "$CACHEDIR/$RKEY.md"
    echo "$(date '+%F %T') brain: refreshed digest '$RKEY' ($(printf '%s' "$OUT" | wc -c | tr -d ' ') chars)" >> "$WF_LOG"
  fi
  rm -f "$CACHEDIR/.refreshing.$RKEY"
  exit 0
fi

# Identity via env first (window titles stay off argv); argv is a manual fallback.
HINT="${1:-${SENTI_SLABEL:-}}"
[ -z "${HINT// /}" ] && exit 0
# The window title's first field is the project.
HINT="${HINT%% — *}"

norm() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cd 'a-z0-9'; }
NH="$(norm "$HINT")"
[ "${#NH}" -lt 3 ] && exit 0   # too short to match anything safely

NOTE=""
# Newline-separated because the vault path contains spaces.
DIRS="${WF_BRAIN_DIRS:-}"
# No folders named, nothing read: the user chooses every folder Senti may look in.
[ -n "$DIRS" ] || exit 0
in_allowlist() {   # vault-relative path inside an allowlisted dir, no escape hatches
  case "$1" in /*|*..*) return 1 ;; esac
  [ -L "$VAULT/$1" ] && return 1
  local rel
  while IFS= read -r rel; do
    case "$1" in "$rel"/*) return 0 ;; esac
  done <<EOF
$DIRS
EOF
  return 1
}

# 1. Explicit map wins (format: project|vault-relative/path.md ; # comments allowed).
# Map entries obey the same allowlist as the scan below; they were a way around it
# (People/ notes, or ../ out of the vault entirely).
if [ -f "$MAP" ]; then
  while IFS='|' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    in_allowlist "$v" || { echo "$(date '+%F %T') brain: map entry for '$k' ignored (outside the allowlist)" >> "$WF_LOG"; continue; }
    NK="$(norm "$k")"
    if [ -n "$NK" ] && { case "$NH" in *"$NK"*) true ;; *) case "$NK" in *"$NH"*) true ;; *) false ;; esac ;; esac }; then
      [ -f "$VAULT/$v" ] && NOTE="$VAULT/$v" && break
    fi
  done < "$MAP"
fi

# 2. Allowlisted dirs, matched by normalized name (either contains the other).
if [ -z "$NOTE" ]; then
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
  echo "$(date '+%F %T') brain: injected cached digest '$KEY'" >> "$WF_LOG"   # not the hint: it is window-title text
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
    # Note PATH via env, not argv: filenames in other vault dirs are people's names,
    # and argv is same-uid readable via `ps` for the call's duration.
    ( SENTI_RNOTE="$NOTE" bash "$HOME/.config/senti/senti-brain.sh" refresh "" "$KEY" >/dev/null 2>&1 & )
  fi
fi

DIGEST="$(brain_digest "$NOTE")"
blank "$DIGEST" && exit 0

echo "$(date '+%F %T') brain: injected '$(basename "$NOTE")' ($(printf '%s' "$DIGEST" | wc -c | tr -d ' ') chars)" >> "$WF_LOG"   # not the hint: it is window-title text
printf 'Project knowledge from the user'"'"'s own notes (their vault is ground truth — trust it over guesses):\n%s\n' "$DIGEST"
