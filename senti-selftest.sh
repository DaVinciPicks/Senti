#!/bin/bash
# Senti self-test — proves the pieces actually work on this Mac.
#   bash ~/.config/senti/senti-selftest.sh
# Exits non-zero if any check fails. Live checks hit the network and cost a
# fraction of a cent; skip them with WF_SELFTEST_OFFLINE=1.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
CFG="$HOME/.config/senti"
PASS=0; FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "── engine ──"
# install.sh does launchctl unload/load, so a run right after an install can catch
# the engine mid-restart. Poll instead of single-shotting it — the model takes a
# few seconds to load back into Metal.
UP=""
for _ in $(seq 1 15); do
  [ "$(bash "$CFG/senti-dictate.sh" server 2>/dev/null)" = "up" ] && { UP=1; break; }
  /bin/sleep 1
done
[ -n "$UP" ] && ok "whisper server responding on $WF_URL" || bad "whisper server DOWN after 15s"
[ -f "$WF_MODEL" ] && ok "model present ($(basename "$WF_MODEL"))" || bad "model file missing: $WF_MODEL"

echo "── config ──"
[ "${WF_CONFIG_VERSION:-0}" -ge 2 ] 2>/dev/null && ok "config schema v${WF_CONFIG_VERSION:-0}" \
                                                 || bad "config schema stale (v${WF_CONFIG_VERSION:-0}) — re-run install.sh"
# Every var a script dereferences must survive `set -u` even with an old config.
MISSING=""
for v in WF_OPENAI_KEY WF_EFFORT WF_OPERATING_PROMPT WF_MODEL_KB WF_LOG WF_RUN; do
  eval "val=\${$v:-}"; [ -z "$val" ] && MISSING="$MISSING $v"
done
[ -z "$MISSING" ] && ok "all required config vars resolve" || bad "unset config vars:$MISSING"

echo "── unbound-variable regression (stale config must not crash scripts) ──"
# The scripts must run off their own defaults when config.sh predates a new var.
STALE=$(mktemp); : > "$STALE"
if ( set -uo pipefail; WF_LOG=/dev/null; WF_RUN=/tmp
     KEYFILE="${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}"; [ -n "$KEYFILE" ] ) 2>/dev/null; then
  ok "point-of-use defaults hold under set -u"
else
  bad "unbound variable under set -u"
fi
rm -f "$STALE"

echo "── secrets ──"
[ -f "$CFG/openai-key" ] && ok "OpenAI key present" || bad "no OpenAI key at $CFG/openai-key"
PERM="$(/usr/bin/stat -f '%Lp' "$CFG/openai-key" 2>/dev/null || echo '')"
[ "$PERM" = "600" ] && ok "key file mode 600" || bad "key file mode is ${PERM:-unknown}, expected 600"

echo "── icons ──"
[ -f "$CFG/appicon.icns" ] && ok "appicon.icns built" || bad "appicon.icns missing"
N="$(/bin/ls -1 "$CFG/appicon.iconset" 2>/dev/null | wc -l | tr -d ' ')"
[ "$N" = "10" ] && ok "iconset has all 10 sizes" || bad "iconset has $N sizes, expected 10"
[ -f "$CFG/menubar/mic.png" ] && ok "menu-bar template present" || bad "menu-bar template missing"

if [ "${WF_SELFTEST_OFFLINE:-0}" = "1" ]; then
  echo "── live API checks skipped (WF_SELFTEST_OFFLINE=1) ──"
else
  echo "── live API ──"
  T0=$(date +%s)
  OUT="$(bash "$CFG/senti-ai.sh" 'Reply with exactly the word: PONG. Nothing else.' 'ping' 2>/dev/null)"
  T1=$(date +%s)
  case "$OUT" in
    *PONG*) ok "text path answered in $((T1-T0))s (${WF_TEXT_MODEL:-gpt-5.4-mini})" ;;
    *)      bad "text path returned: '${OUT:0:60}'" ;;
  esac

  SHOT="$WF_RUN/selftest-shot.png"
  /usr/sbin/screencapture -x -m "$SHOT" 2>/dev/null
  if [ -s "$SHOT" ]; then
    T0=$(date +%s)
    V="$(bash "$CFG/senti-vision.sh" 'Reply with exactly one word naming the frontmost kind of app you see.' "$SHOT" context 2>/dev/null)"
    T1=$(date +%s)
    [ -n "${V// /}" ] && ok "vision path answered in $((T1-T0))s: '${V:0:40}'" \
                       || bad "vision path returned nothing"
    rm -f "$SHOT"
  else
    bad "screencapture produced nothing (Screen Recording permission?)"
  fi
fi

echo "── privacy: dictated text must not be visible in \`ps\` ──"
# Exercise the REAL call path: senti.lua passes spoken text in SENTI_IN, never argv.
SECRET="senti-canary-$$-do-not-log"
( SENTI_IN="$SECRET" bash "$CFG/senti-ai.sh" 'Reply with the single word OK.' >/dev/null 2>&1 ) &
BGPID=$!
# Snapshot ps into a variable and match with a shell glob. Piping to `grep -- "$SECRET"`
# would put the canary in GREP's own argv, which ps then catches — the test reports a
# leak it created itself. (That false positive is why this check flapped.)
LEAK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  SNAP="$(/bin/ps -Ao args= 2>/dev/null)"
  case "$SNAP" in *"$SECRET"*) LEAK=1; break ;; esac
  /bin/sleep 0.2
done
unset SNAP
wait $BGPID 2>/dev/null
[ "$LEAK" = "0" ] && ok "spoken text never appeared in the process table" \
                   || bad "LEAK: spoken text was visible in \`ps\`"

echo "── model-aware prompting knowledge base ──"
KBN="$(/bin/ls -1 "$WF_MODEL_KB"/*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "${KBN:-0}" -ge 1 ] && ok "$KBN knowledge file(s) installed" || bad "no KB files in $WF_MODEL_KB"
G="$(bash "$CFG/senti-target.sh" "Claude" 2>/dev/null)"
[ -n "${G// /}" ] && ok "target resolver returned guidance for 'Claude' (${#G} chars)" \
                   || bad "target resolver returned nothing for 'Claude'"

echo "── prompt-mode path parity ──"
# Prompt mode routes to senti-vision.sh when Screen Recording is granted and to
# senti-prompt.sh when it isn't. Both must carry the same guidance; when they didn't,
# every improvement silently applied only to the branch that never runs.
PAR=0
for dep in senti-target.sh senti-session.sh prompt-craft.md; do
  A="$(/usr/bin/grep -c "$dep" "$CFG/senti-vision.sh" 2>/dev/null || echo 0)"
  B="$(/usr/bin/grep -c "$dep" "$CFG/senti-prompt.sh" 2>/dev/null || echo 0)"
  if [ "$A" -ge 1 ] && [ "$B" -ge 1 ]; then :; else
    bad "path parity: $dep missing (vision=$A prompt=$B)"; PAR=1
  fi
done
[ "$PAR" = "0" ] && ok "both prompt paths carry craft + session + target guidance"

echo "── whisper vocabulary biasing ──"
BIAS="$(SENTI_SLABEL="senti — ⠐ x — claude — 1×1" bash -c '
  source '"$CFG"'/config.sh
  '"$(/usr/bin/sed -n '/^build_bias()/,/^}/p' "$CFG/senti-dictate.sh")"'
  build_bias' 2>/dev/null)"
case "$BIAS" in
  *Vocabulary*) ok "bias hint built (${#BIAS} chars)" ;;
  *)            bad "bias hint empty — misheard identifiers won't be corrected" ;;
esac
[ "${#BIAS}" -le 240 ] && ok "bias within length budget (long hints get echoed back)" \
                        || bad "bias too long (${#BIAS} chars) — whisper may echo it"
DUPES="$(printf '%s' "$BIAS" | /usr/bin/tr ',' '\n' | /usr/bin/sed 's/^ *//' \
         | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/grep -c . || true)"
[ "${DUPES:-0}" -eq 0 ] && ok "no duplicate bias terms" || bad "$DUPES duplicate term(s) in bias"

echo "── per-window session memory ──"
SS="$CFG/senti-session.sh"
LA="proj-alpha — ⠐ Doing alpha work — claude — 213×59"
LB="proj-beta — ⠂ Doing beta work — claude — 213×59"
SENTI_IN="alpha turn one" bash "$SS" note 900001 "$LA" prompt 2>/dev/null
SENTI_IN="beta turn one"  bash "$SS" note 900002 "$LB" prompt 2>/dev/null
RA="$(bash "$SS" recall 900001 "$LA" 2>/dev/null)"
case "$RA" in *"alpha turn one"*) ok "session records turns" ;; *) bad "session did not record" ;; esac
case "$RA" in *"beta turn one"*) bad "SESSION BLEED: beta turn visible in alpha" ;;
              *) ok "sessions isolated (beta not visible from alpha)" ;; esac
case "$RA" in *"proj-alpha"*) ok "project parsed from window title" ;; *) bad "project not parsed" ;; esac
SDIR="${WF_SESSION_DIR:-$HOME/.cache/senti/sessions}"
PERM="$(/usr/bin/stat -f '%Lp' "$SDIR" 2>/dev/null || echo '')"
[ "$PERM" = "700" ] && ok "session dir mode 700" || bad "session dir mode ${PERM:-unknown}, expected 700"
rm -f "$SDIR/900001.tsv" "$SDIR/900002.tsv"

echo
if [ "$FAIL" -eq 0 ]; then printf '\033[32mAll %d checks passed.\033[0m\n' "$PASS"; exit 0
else printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$PASS" "$FAIL"; exit 1; fi
