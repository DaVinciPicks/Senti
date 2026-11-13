#!/bin/bash
# Second-brain bridge: pull a SMALL digest of the user's own notes for the project
# they're working in, so prompt mode knows what the project actually is.
#
#   senti-brain.sh <project-hint>             # e.g. "senti", "davincibets_main"
#   senti-brain.sh --preview <project-hint>   # print, locally, what would ride a heavy
#                                             # Prompt turn and where it would go; no network
#
# Prints a capped digest, or nothing. Sources, in order:
#   1. an explicit mapping in brain-map.txt (project|path/to/note.md, vault-relative)
#   2. an allowlisted dir whose name matches the project → its <dir>/<dir>.md
#      (or the single .md inside, if the convention isn't followed)
#
# PRIVACY MODEL — read before widening anything here:
#   - Whatever this prints can be injected into prompt mode and then RIDES THE API CALL to
#     the active AI provider (OpenAI, Anthropic or OpenRouter). That is the entire point,
#     and also the entire risk. It rides only heavy turns (senti_intent in senti-lib.sh).
#   - So: only the folders listed in WF_BRAIN_DIRS are ever searched. There is no
#     default list, and the whole bridge is off unless WF_BRAIN=1.
#   - Digest is hard-capped (WF_BRAIN_MAX chars). A note can control exactly what
#     Senti sees by adding a "## Senti" section — then ONLY that section is used.
#   - The log says "brain: prepared" when a digest is built (that happens at key-down, when
#     nothing has left the Mac) and senti-lib.sh logs "sent: vault" only when the digest
#     joins a request. Kill switch: WF_BRAIN=0.
#   - There is no background upload. A lazy background step that sent the digest to the
#     model to compress it was deleted on 13 Nov 2026: it had not run since 17 Oct (the
#     key-down prefetch disabled it) and it was one more upload than the feature needs.
#   - Verbatim dictation never touches this script.
set -uo pipefail
# Blank test that stays O(n) on bash 3.2 (${VAR// /} is quadratic there: 8 KB took 4.8s).
blank() { case "$1" in *[![:space:]]*) return 1 ;; *) return 0 ;; esac; }
source "$HOME/.config/senti/config.sh"

PREVIEW=0
if [ "${1:-}" = "--preview" ]; then PREVIEW=1; shift; fi
if [ "${WF_BRAIN:-0}" != "1" ]; then   # opt-in: off unless config.sh sets WF_BRAIN=1
  [ "$PREVIEW" = 1 ] && echo "The notes bridge is off (WF_BRAIN is not 1), so nothing from your notes is sent."
  exit 0
fi
VAULT="${WF_VAULT:-$HOME/Documents/Obsidian Vault}"
[ -d "$VAULT" ] || { [ "$PREVIEW" = 1 ] && echo "No vault at WF_VAULT, so nothing from your notes is sent."; exit 0; }
MAX="${WF_BRAIN_MAX:-700}"
MAP="${WF_BRAIN_MAP:-$HOME/.config/senti/brain-map.txt}"

# Extract the shippable digest from a note, in order of preference:
#   "## Senti" section       → the note author's explicit choice of what Senti may see
#                              (legacy "## Sanele" too: the heading is a privacy control,
#                              and a rename that misses one note must not fall through
#                              to the broader fallbacks below — it did once, 2026-08-19)
#   "## For future Claude"   → already written for AI consumption
#   else                     → first body lines after the frontmatter
# Wiki-link noise stripped, hard-capped at WF_BRAIN_MAX. This is the ONE gate that keeps
# private note content from leaving the Mac: every path that can send note text goes
# through it. Never send a raw note.
brain_digest() {
  local f="$1" d
  d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## (?:Senti|Sanele)\s*\n(.*?)(?=^## |\z)/ms' "$f")"
  blank "$d" && d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## For future Claude\s*\n(.*?)(?=^## |\z)/ms' "$f")"
  blank "$d" && d="$(/usr/bin/perl -0777 -pe 's/\A---\n.*?\n---\n//s' "$f" | /usr/bin/grep -v '^#' | /usr/bin/grep -v '^\s*$' | head -10)"
  printf '%s' "$d" \
    | /usr/bin/perl -pe 's/\[\[[^\]|]*\|([^\]]*)\]\]/$1/g; s/\[\[([^\]]*)\]\]/$1/g' \
    | cut -c1-100000 | head -c "$MAX"
}

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
[ -n "$DIRS" ] || { [ "$PREVIEW" = 1 ] && echo "WF_BRAIN_DIRS lists no folders, so nothing from your notes is sent."; exit 0; }
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

if [ -z "$NOTE" ] || [ ! -f "$NOTE" ]; then
  [ "$PREVIEW" = 1 ] && echo "No note in your allowed folders matches '$HINT', so nothing from your notes is sent."
  exit 0
fi

DIGEST="$(brain_digest "$NOTE")"
blank "$DIGEST" && { [ "$PREVIEW" = 1 ] && echo "The matching note has nothing to send."; exit 0; }
NAME="$(basename "$NOTE")"
NCH="$(printf '%s' "$DIGEST" | wc -c | tr -d ' ')"

if [ "$PREVIEW" = 1 ]; then
  source "$HOME/.config/senti/senti-key.sh"
  senti_ai_resolve text
  echo "On a heavy Prompt turn (one that opens with \"think hard\" or \"today let's work on\"),"
  echo "Senti would send these $NCH characters from '$NAME' (cap $MAX) to $(senti_provider_label "$SENTI_R_PROVIDER") ($SENTI_R_MODEL):"
  echo "────"
  printf '%s\n' "$DIGEST"
  echo "────"
  exit 0
fi

# senti-lib.sh asks for the note name (to log "sent: vault" and fill last-request.json)
# through a file it names, under the ctx- prefix so the cache sweep removes it.
if [ -n "${SENTI_BRAIN_NOTEOUT:-}" ]; then printf '%s' "$NAME" > "$SENTI_BRAIN_NOTEOUT" 2>/dev/null; fi
# Built, not sent: that is decided per turn in senti-lib.sh. Not the hint: it is window-title text.
echo "$(date '+%F %T') brain: prepared '$NAME' $NCH chars" >> "$WF_LOG"
printf 'Project knowledge from the user'"'"'s own notes (their vault is ground truth — trust it over guesses):\n%s\n' "$DIGEST"
