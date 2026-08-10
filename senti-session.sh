#!/bin/bash
# Per-session memory. You run several terminals at once; without this, every dictation
# is context-free and "do the same for the other one" is meaningless.
#
#   senti-session.sh note   <key> <label> <mode>   # append a turn (text in SENTI_IN)
#   senti-session.sh recall <key> <label>          # print context block for this session
#   senti-session.sh sweep                         # drop sessions older than WF_SESSION_TTL_H
#
# Identity comes from the focused WINDOW id, so three Claude Code terminals are three
# distinct sessions even though they're all "Terminal". The window title already carries
# the project and the current task, e.g.
#   "senti — ⠐ Evaluate software for commercial viability — caffeinate ◂ claude … — 213×59"
# so we get the working context for free — no screenshots, no API call, nothing leaves
# the Mac. Everything here is local text under ~/.cache/senti/sessions.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

DIR="${WF_SESSION_DIR:-$HOME/.cache/senti/sessions}"
KEEP="${WF_SESSION_TURNS:-12}"      # turns of history retained per session
TTL_H="${WF_SESSION_TTL_H:-24}"     # hours before a session file is considered stale
mkdir -p "$DIR" 2>/dev/null
chmod 700 "$DIR" 2>/dev/null        # it holds transcripts of your speech

CMD="${1:-recall}"
KEY="${2:-}"
LABEL="${3:-}"
MODE="${4:-}"

# Window titles are "project — status task — command — dims". Pull the useful fields.
proj()  { printf '%s' "$1" | /usr/bin/awk -F ' — ' '{print $1}' | /usr/bin/sed 's/^ *//;s/ *$//'; }
task()  { printf '%s' "$1" | /usr/bin/awk -F ' — ' '{print $2}' \
          | /usr/bin/sed 's/^[^[:alnum:]]*//; s/^ *//; s/ *$//'; }

safe_key() { printf '%s' "${1:-unknown}" | /usr/bin/tr -cd '[:alnum:]._-' | cut -c1-64; }
FILE="$DIR/$(safe_key "$KEY").tsv"

case "$CMD" in
  note)
    TEXT="${SENTI_IN:-}"
    [ -z "${TEXT// /}" ] && exit 0
    # One line per turn: time, mode, and the utterance flattened + clipped.
    FLAT="$(printf '%s' "$TEXT" | /usr/bin/tr '\n\t' '  ' | cut -c1-200)"
    printf '%s\t%s\t%s\n' "$(date '+%H:%M')" "${MODE:-dictate}" "$FLAT" >> "$FILE"
    chmod 600 "$FILE" 2>/dev/null
    # Trim in place to the last N turns.
    if [ "$(wc -l < "$FILE" 2>/dev/null || echo 0)" -gt "$KEEP" ]; then
      T="$(mktemp)"; tail -n "$KEEP" "$FILE" > "$T" && mv "$T" "$FILE"; chmod 600 "$FILE" 2>/dev/null
    fi
    ;;

  recall)
    P="$(proj "$LABEL")"; T="$(task "$LABEL")"
    OUT=""
    [ -n "$P" ] && OUT="Working directory / project: $P"
    [ -n "$T" ] && OUT="$OUT
What this session is currently doing: $T"
    if [ -s "$FILE" ]; then
      OUT="$OUT
Recent turns in THIS session (most recent last) — use them to resolve references like \"that\", \"the same\", \"the other one\":
$(/usr/bin/awk -F '\t' '{printf "  [%s %s] %s\n", $1, $2, $3}' "$FILE")"
    fi
    [ -n "${OUT// /}" ] && printf 'Session context (local, never left this Mac):\n%s\n' "$OUT"
    ;;

  sweep)
    # Sessions are transcripts of your speech — don't keep them around indefinitely.
    N=0
    if [ -d "$DIR" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f" && N=$((N+1))
      done <<EOF
$(/usr/bin/find "$DIR" -type f -name '*.tsv' -mmin +$((TTL_H * 60)) 2>/dev/null)
EOF
    fi
    echo "$N"
    ;;

  *) echo "usage: senti-session.sh {note|recall|sweep} <key> <label> [mode]" >&2; exit 1 ;;
esac
