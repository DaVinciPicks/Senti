#!/bin/bash
# sanele dictation engine.
#   start   — begin recording the mic (backgrounds sox, writes a pidfile)
#   stop    — finish recording, transcribe, print cleaned text to stdout
#   toggle  — stop if recording, else start  (used by hands-free hotkey)
#   cancel  — abort recording, transcribe nothing
#   status  — "recording" | "idle"
#   server  — "up" | "down"
# Hold-to-talk = start on key-down, stop on key-up. Toggle = tap to start/stop.
set -uo pipefail
source "$HOME/.config/sanele/config.sh"
umask 077   # audio/screenshot/selection files created here are uid-private

# The log lives alongside speech-derived data; keep it uid-only, not the umask default.
[ -f "$WF_LOG" ] || : >> "$WF_LOG"; chmod 600 "$WF_LOG" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$WF_LOG"; }
# The redirect MUST wrap the whole group, not just afplay. `cmd >/dev/null &` backgrounds
# the entire && chain as one subshell, and that subshell inherits this script's stdout —
# which is a PIPE (sanele.lua reads it via hs.task; a shell reads it via $( )). The reader
# waits for EOF on that pipe, so it waited for afplay to finish playing: MEASURED 2392ms
# with sound vs 539ms without, i.e. every single dictation paid ~1.85s waiting for the
# stop chime. Redirecting the group detaches the subshell's stdout before it forks.
cue() { { [ "$WF_SOUNDS" = "1" ] && [ -f "$1" ] && afplay "$1"; } >/dev/null 2>&1 & }

server_up() { "$WF_CURL" -s -o /dev/null -m 1 "$WF_URL/" 2>/dev/null; }

is_recording() {
  [ -f "$WF_PIDFILE" ] && kill -0 "$(cat "$WF_PIDFILE" 2>/dev/null)" 2>/dev/null
}

start() {
  if is_recording; then log "start ignored: already recording"; return 0; fi
  rm -f "$WF_AUDIO"
  cue "$WF_SOUND_START"
  # -d default input, quiet, 16kHz mono 16-bit signed PCM (Whisper's native format).
  "$WF_SOX" -d -q -r 16000 -c 1 -b 16 -e signed-integer "$WF_AUDIO" >/dev/null 2>>"$WF_LOG" &
  echo $! >"$WF_PIDFILE"
  log "recording started (pid $!)"
}

# Interrupt sox with SIGINT so it rewrites the WAV header, then wait for the file to settle.
finish_recording() {
  local pid
  pid="$(cat "$WF_PIDFILE" 2>/dev/null)"
  rm -f "$WF_PIDFILE"
  [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null
  # Poll fast (20ms) so we proceed the instant sox finalizes the WAV header.
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 0.02
  done
}

# Build the whisper vocabulary hint from context that costs nothing to obtain.
# Kept short on purpose: an over-long hint makes whisper echo the hint text back
# instead of transcribing, which is worse than no hint at all. Disable with WF_BIAS=0.
build_bias() {
  [ "${WF_BIAS:-1}" = "1" ] || return 0
  local terms="" proj branch
  # Project name from the focused window title (sanele.lua passes it through).
  proj="$(printf '%s' "${SANELE_SLABEL:-}" | /usr/bin/awk -F ' — ' '{print $1}' \
          | /usr/bin/tr -cd '[:alnum:]._ -' | cut -c1-40)"
  # A window title is attacker-controllable (a web page sets its own browser-tab
  # title), and proj is later used as a path component under ~/code. tr already
  # strips slashes, but "." / ".." survive and would point git at ~/code or its
  # parent — reject them so the path can only ever name a direct child of ~/code.
  case "$proj" in .|..|*/*) proj="" ;; esac
  [ -n "${proj// /}" ] && terms="$proj"
  # Current git branch, if the focused project maps to a repo we can see.
  if [ -n "${proj// /}" ] && [ -d "$HOME/code/$proj/.git" ]; then
    branch="$(/usr/bin/git -C "$HOME/code/$proj" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && terms="$terms, $branch"
  fi
  # Replacement targets are, by definition, words this user says and whisper mishears.
  if [ -f "$WF_REPLACEMENTS" ]; then
    local dict
    # Dedupe: several "what whisper hears" lines legitimately map to the SAME target
    # (cloud md / cloud dot md → CLAUDE.md), and repeating a term in the hint just burns
    # the budget that keeps whisper from echoing the hint instead of transcribing.
    dict="$(/usr/bin/awk -F '|' '!/^[[:space:]]*#/ && NF>1 {print $2}' "$WF_REPLACEMENTS" \
            | /usr/bin/awk '!seen[$0]++' \
            | /usr/bin/head -12 | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//; s/,/, /g')"
    [ -n "${dict// /}" ] && terms="${terms:+$terms, }$dict"
  fi
  [ -z "${terms// /}" ] && return 0
  # Logged so a mistranscription can be debugged against what the hint actually was.
  log "bias: $terms"
  printf 'Vocabulary: %s.' "$(printf '%s' "$terms" | cut -c1-220)"
}

transcribe() {
  [ -s "$WF_AUDIO" ] || { log "no audio to transcribe"; return 0; }
  # Silence gate: real speech peaks well above 0.02; a quiet room sits near 0.0.
  # Skipping near-silent clips stops Whisper hallucinating "Thank you." on nothing.
  # One sox pass gives both the peak (silence gate) and the length (audio_ctx gate).
  local stat peak dur
  stat="$("$WF_SOX" "$WF_AUDIO" -n stat 2>&1)"
  peak="$(printf '%s' "$stat" | /usr/bin/awk '/Maximum amplitude/{print $3}')"
  dur="$(printf '%s' "$stat" | /usr/bin/awk '/^Length \(seconds\)/{print $3}')"
  # Fail OPEN: only gate when we actually measured a peak below threshold. If sox stat
  # failed (empty peak), transcribe anyway rather than silently dropping real speech.
  if [ -n "$peak" ] && /usr/bin/awk -v p="$peak" -v t="${WF_SILENCE_THOLD:-0.005}" 'BEGIN{exit !(p+0 < t+0)}'; then
    # A peak of EXACTLY 0.000000 is not a quiet room — it's the documented mic-TCC
    # signature: macOS silently mutes sox's CoreAudio-HAL input when Hammerspoon lacks
    # Microphone permission, with no prompt. Distinguishing the two turns a mystery
    # ("I spoke for a minute and nothing happened") into one actionable instruction.
    if /usr/bin/awk -v p="$peak" 'BEGIN{exit !(p+0 == 0)}'; then
      log "silence gate: peak 0.000000 — mic captured NO audio (permission/muted input)"
      echo "__WF_MIC_DEAD__"
    else
      log "silence gate: peak $peak below threshold — skipped as silence"
    fi
    return 0
  fi
  if ! server_up; then
    log "server down — cannot transcribe"
    echo "__WF_SERVER_DOWN__"
    return 0
  fi
  # Vocabulary biasing: whisper takes an `prompt` hint that steers decoding toward
  # words it expects to hear. Costs nothing, runs locally, and is the cheapest fix for
  # the #1 dictation complaint — mangled project names and code identifiers. The terms
  # come from where you already are: the project from the focused window title, the git
  # branch, and the right-hand side of your custom dictionary.
  local bias
  bias="$(build_bias)"

  # audio_ctx: shrink whisper's encoder window on SHORT clips. Measured on this Mac
  # (large-v3-turbo, 6s clip): 833ms → 418ms, byte-identical transcript. It is a 2x win
  # on the common case, because most of whisper's cost is a fixed encoder toll that
  # barely scales with clip length.
  # STRICTLY duration-gated, because past ~12s it does not just get slower — it
  # TRUNCATES. Measured at ctx=768: 8s identical, 12s identical, 16s diverged AND took
  # 2803ms (3x slower than default), losing the end of the recording entirely. Silently
  # dropping the end of a long dictation is the worst failure this app can have, so the
  # gate is set at 10s — a deliberate margin below the last length proven safe.
  local ctx_arg=""
  if [ -n "$dur" ] && /usr/bin/awk -v d="$dur" -v m="${WF_AUDIO_CTX_MAX_SEC:-10}" 'BEGIN{exit !(d+0 > 0 && d+0 < m+0)}'; then
    ctx_arg="${WF_AUDIO_CTX:-768}"
  fi

  local raw
  if [ -n "$ctx_arg" ] && [ -n "${bias// /}" ]; then
    raw="$("$WF_CURL" -s -m 30 "$WF_URL/inference" \
          -F file=@"$WF_AUDIO" \
          -F temperature=0.0 \
          -F audio_ctx="$ctx_arg" \
          --form-string "prompt=$bias" \
          -F response_format=text 2>>"$WF_LOG")"
  elif [ -n "$ctx_arg" ]; then
    raw="$("$WF_CURL" -s -m 30 "$WF_URL/inference" \
          -F file=@"$WF_AUDIO" \
          -F temperature=0.0 \
          -F audio_ctx="$ctx_arg" \
          -F response_format=text 2>>"$WF_LOG")"
  elif [ -n "${bias// /}" ]; then
    # --form-string, not -F: -F parses ';' in the value as a multipart attribute
    # separator and silently truncates the hint (branch names can contain ';').
    raw="$("$WF_CURL" -s -m 30 "$WF_URL/inference" \
          -F file=@"$WF_AUDIO" \
          -F temperature=0.0 \
          --form-string "prompt=$bias" \
          -F response_format=text 2>>"$WF_LOG")"
  else
    raw="$("$WF_CURL" -s -m 30 "$WF_URL/inference" \
          -F file=@"$WF_AUDIO" \
          -F temperature=0.0 \
          -F response_format=text 2>>"$WF_LOG")"
  fi
  clean_text "$raw"
}

# Trim whitespace; drop pure non-speech artifacts like [BLANK_AUDIO], (silence), *music*.
clean_text() {
  local t
  t="$(printf '%s' "$1" | /usr/bin/tr '\n' ' ' \
       | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
  # If the entire result is a single bracketed/parenthesised/asterisked token, it's noise.
  if printf '%s' "$t" | /usr/bin/grep -Eq '^(\[[^]]*\]|\([^)]*\)|\*[^*]*\*)$'; then
    printf ''; return
  fi
  # Smart Formatting: drop filler tokens (um/uh/erm/hmm) anywhere, and one leading
  # discourse marker (so/okay/well/like), then re-capitalise the first letter.
  if [ "${WF_REMOVE_FILLERS:-1}" = "1" ]; then
    t="$(printf '%s' "$t" | /usr/bin/awk '{
      n=split($0,w," "); out="";
      for(i=1;i<=n;i++){ tok=w[i]; base=tolower(tok); sub(/[.,!?;:]+$/,"",base);
        if(base ~ /^(um+|uh+|uhm+|erm+|hmm+)$/) continue;
        if(i==1 && n>2 && base ~ /^(so|okay|ok|well|like)$/) continue;
        out=(out==""?tok:out" "tok); }
      if(length(out)>0) out=toupper(substr(out,1,1)) substr(out,2);
      print out; }')"
  fi
  # Custom dictionary: literal, case-insensitive phrase fixes from replacements.txt.
  if [ -f "$WF_REPLACEMENTS" ]; then
    t="$(printf '%s' "$t" | /usr/bin/perl -e '
      my $rf = shift; my @rules;
      if (open(my $fh, "<", $rf)) {
        while (<$fh>) { chomp; next if /^\s*#/ || !/\|/;
          my ($p,$r) = split(/\|/, $_, 2); push @rules, [$p,$r]; }
      }
      local $/; my $x = <STDIN>;
      for my $ru (@rules) { my ($p,$r)=@$ru; $x =~ s/\Q$p\E/$r/gi; }
      print $x;' "$WF_REPLACEMENTS")"
  fi
  printf '%s' "$t"
}

stop() {
  finish_recording
  cue "$WF_SOUND_STOP"
  local text; text="$(transcribe)"
  # Don't archive the transcript. sanele.log is never rotated, so logging the text made
  # it a permanent plaintext record of everything ever said — outliving the 24h session
  # expiry the rest of the app enforces. Log length only; full text behind WF_DEBUG=1.
  if [ "${WF_DEBUG:-0}" = "1" ]; then
    log "transcribed: ${text:-<empty>}"
  else
    log "transcribed: ${#text} chars"
  fi
  printf '%s' "$text"
}

# Record a fixed 1.2s clip and print peak amplitude (0.000000 = mic blocked/silent).
# Used by the menubar "Test microphone" item to trigger the TCC prompt + verify.
mictest() {
  local f="$WF_RUN/mictest.wav"
  rm -f "$f"
  "$WF_SOX" -d -q -r 16000 -c 1 -b 16 "$f" trim 0 1.2 >/dev/null 2>>"$WF_LOG"
  if [ -s "$f" ]; then
    "$WF_SOX" "$f" -n stat 2>&1 | /usr/bin/awk '/Maximum amplitude/{print $3}'
  else
    echo "NO_MIC"
  fi
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  mictest) mictest ;;
  toggle) if is_recording; then stop; else start; fi ;;
  cancel) finish_recording; rm -f "$WF_AUDIO"; log "cancelled" ;;
  status) is_recording && echo recording || echo idle ;;
  server) server_up && echo up || echo down ;;
  *) echo "usage: sanele-dictate.sh {start|stop|toggle|cancel|status|server}" >&2; exit 1 ;;
esac
