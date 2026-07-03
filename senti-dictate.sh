#!/bin/bash
# senti dictation engine.
#   start   — begin recording the mic (backgrounds sox, writes a pidfile)
#   stop    — finish recording, transcribe, print cleaned text to stdout
#   toggle  — stop if recording, else start  (used by hands-free hotkey)
#   cancel  — abort recording, transcribe nothing
#   status  — "recording" | "idle"
#   server  — "up" | "down"
# Hold-to-talk = start on key-down, stop on key-up. Toggle = tap to start/stop.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$WF_LOG"; }
cue() { [ "$WF_SOUNDS" = "1" ] && [ -f "$1" ] && afplay "$1" >/dev/null 2>&1 & }

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

transcribe() {
  [ -s "$WF_AUDIO" ] || { log "no audio to transcribe"; return 0; }
  # Silence gate: real speech peaks well above 0.02; a quiet room sits near 0.0.
  # Skipping near-silent clips stops Whisper hallucinating "Thank you." on nothing.
  local peak
  peak="$("$WF_SOX" "$WF_AUDIO" -n stat 2>&1 | /usr/bin/awk '/Maximum amplitude/{print $3}')"
  if /usr/bin/awk -v p="${peak:-0}" -v t="${WF_SILENCE_THOLD:-0.005}" 'BEGIN{exit !(p+0 < t+0)}'; then
    log "silence gate: peak ${peak:-0} below threshold — skipped"
    return 0
  fi
  if ! server_up; then
    log "server down — cannot transcribe"
    echo "__WF_SERVER_DOWN__"
    return 0
  fi
  local raw
  raw="$("$WF_CURL" -s -m 30 "$WF_URL/inference" \
        -F file=@"$WF_AUDIO" \
        -F temperature=0.0 \
        -F response_format=text 2>>"$WF_LOG")"
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
  log "transcribed: ${text:-<empty>}"
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
  *) echo "usage: senti-dictate.sh {start|stop|toggle|cancel|status|server}" >&2; exit 1 ;;
esac
