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
# Static check with teeth (the old version was a tautology that never read the
# scripts): every brace-form WF_ variable dereferenced WITHOUT a :- default in any
# deployed script must be defined unconditionally by config.sh — otherwise a
# pre-upgrade config crashes that script under set -u at runtime. NB: this comment
# must not spell the literal pattern, because the scan includes this file.
MISS=""
BARE="$(/usr/bin/grep -ohE '\$\{WF_[A-Z_0-9]+\}' "$CFG"/senti-*.sh 2>/dev/null \
        | /usr/bin/sort -u | /usr/bin/tr -d '${}')"
for v in $BARE; do
  /usr/bin/grep -qE "^[[:space:]]*(export[[:space:]]+)?${v}=" "$CFG/config.sh" || MISS="$MISS $v"
done
[ -z "$MISS" ] && ok "every bare \${WF_*} deref is unconditionally defined in config.sh" \
               || bad "bare deref with no config.sh definition:$MISS"

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
    *PONG*) ok "text path answered in $((T1-T0))s (${WF_TEXT_MODEL:-gpt-5.6-luna})" ;;
    *)      bad "text path returned: '${OUT:0:60}'" ;;
  esac

  # Screenshot lives OUTSIDE ~/.cache/senti: Hammerspoon's 60s idle sweeper deletes
  # wf.SWEEPABLE files there, and an external selftest run races it (flapping failure).
  SHOT="$(mktemp -d)/selftest-shot.png"
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
# Exercise the REAL call path and BOTH env channels: SENTI_IN (spoken text) and
# SENTI_SYS (system prompt — it embeds session transcripts + vault digests, so it is
# just as sensitive; a canary only in SENTI_IN missed exactly that leak once).
SECRET="senti-canary-$$-do-not-log"
( SENTI_SYS="Reply with the single word OK. (ctx: $SECRET)" SENTI_IN="$SECRET" \
    bash "$CFG/senti-ai.sh" >/dev/null 2>&1 ) &
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
# Browsers: the app name must never pick a model family ("Google Chrome" once matched
# the google/Gemini KB); the TAB title decides, and no title → universal only.
GB="$(SENTI_SLABEL="Claude — chat — Google Chrome" bash "$CFG/senti-target.sh" "Google Chrome" 2>/dev/null)"
case "$GB" in *Anthropic*) ok "browser hint resolves by tab title (Claude tab → Anthropic)" ;;
              *) bad "browser tab title not resolved (got ${#GB} chars)" ;; esac
GN="$(SENTI_SLABEL="" bash "$CFG/senti-target.sh" "Google Chrome" 2>/dev/null)"
case "$GN" in *Gemini*|*Anthropic*|*OpenAI*) bad "bare browser name picked a model family" ;;
              *) ok "bare browser name → universal guidance only" ;; esac

echo "── prompt-mode path parity ──"
# Parity is STRUCTURAL now: both paths source senti-lib.sh and call
# senti_prompt_context, which owns craft + brain + session + target assembly.
# The checks assert (a) both paths use the shared function, (b) the lib actually
# still wires all four dependencies — so a drift reintroduction fails loudly.
PAR=0
for f in senti-vision.sh senti-prompt.sh; do
  /usr/bin/grep -q 'senti-lib.sh' "$CFG/$f" && /usr/bin/grep -q 'senti_prompt_context' "$CFG/$f" \
    || { bad "path parity: $f does not use the shared context lib"; PAR=1; }
done
for dep in senti-target.sh senti-session.sh senti-brain.sh prompt-craft.md; do
  /usr/bin/grep -q "$dep" "$CFG/senti-lib.sh" 2>/dev/null \
    || { bad "path parity: senti-lib.sh lost its $dep wiring"; PAR=1; }
done
[ "$PAR" = "0" ] && ok "both paths share one context lib carrying craft + brain + session + target"
# The shared function must actually emit for a known project (env-only identity).
LCTX="$(SENTI_SLABEL="senti — x — y" SENTI_SKEY="" SENTI_HINT="Claude" WF_BRAIN_REFRESH=0 \
        bash -c 'source "'"$CFG"'/config.sh"; source "'"$CFG"'/senti-lib.sh"; senti_prompt_context' 2>/dev/null)"
case "$LCTX" in
  *"How to build the prompt"*) ok "shared context emits craft (+$( printf '%s' "$LCTX" | /usr/bin/grep -c '^--- ' ) sections, ${#LCTX} chars)" ;;
  *) bad "shared context function emitted nothing" ;;
esac

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

echo "── second brain (vault bridge) ──"
BV="${WF_VAULT:-$HOME/Documents/Obsidian Vault}"
if [ ! -d "$BV" ] || [ "${WF_BRAIN:-1}" != "1" ]; then
  ok "vault absent or WF_BRAIN=0 — brain checks skipped"
else
  # Positive: a real project resolves. Refresh disabled so the check costs $0.
  BOUT="$(WF_BRAIN_REFRESH=0 bash "$CFG/senti-brain.sh" "senti — ⠐ x — claude — 1×1" 2>/dev/null)"
  [ -n "${BOUT// /}" ] && ok "brain resolves 'senti' (${#BOUT} chars)" \
                        || bad "brain returned nothing for 'senti'"
  # Privacy: names that are NOT allowlisted projects must resolve to NOTHING.
  # The People/ probe is derived from the vault AT RUNTIME so no real name is ever
  # committed to the repo (house rule: names were scrubbed from files and history).
  PPROBE="$(/bin/ls "$BV/People" 2>/dev/null | head -1 | /usr/bin/sed 's/\.md$//')"
  if [ -n "${PPROBE// /}" ]; then
    PB="$(WF_BRAIN_REFRESH=0 bash "$CFG/senti-brain.sh" "$PPROBE" 2>/dev/null)"
    [ -z "${PB// /}" ] && ok "brain refuses a real People/ note (probe derived at runtime)" \
                        || bad "PRIVACY: brain leaked a People/ note"
  fi
  PB="$(WF_BRAIN_REFRESH=0 bash "$CFG/senti-brain.sh" "randomxyzq" 2>/dev/null)"
  [ -z "${PB// /}" ] && ok "brain refuses an unknown project" || bad "brain leaked content for garbage hint"
  BPERM="$(/usr/bin/stat -f '%Lp' "$HOME/.cache/senti/brain" 2>/dev/null || echo '')"
  [ "$BPERM" = "700" ] && ok "brain cache dir mode 700" || bad "brain cache dir mode ${BPERM:-unknown}"
fi

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
