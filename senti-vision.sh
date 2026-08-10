#!/bin/bash
# Vision mode: read a screenshot of the user's screen + a spoken instruction.
#   $1 = spoken instruction (transcribed)
#   $2 = path to the screenshot PNG
#   $3 = kind: "context" (draft reply/edit at cursor) | "prompt" (generate an
#        optimized prompt that folds in the on-screen working context)
# Engine: gpt-5.6-luna (~1.4s, ~$0.0004/call — vs gpt-4o-mini's 3.3s, 37k tokens, $0.0056).
# Prints ONLY the text to insert.
#
# Instruction text goes via ENV, never argv — argv is visible in `ps` to any local process.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

# Spoken instruction arrives in SENTI_IN, never argv (see senti-ai.sh).
INSTR="${SENTI_IN:-${1:-}}"
SHOT="${2:-}"
KIND="${3:-context}"
[ -z "${INSTR// /}" ] && exit 0
[ -f "$SHOT" ] || { printf ''; exit 0; }

KEYFILE="${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}"
KEY=""
[ -f "$KEYFILE" ] && KEY="$(/usr/bin/tr -d '[:space:]' < "$KEYFILE")"
[ -z "$KEY" ] && { echo "no OpenAI key at $KEYFILE" >>"$WF_LOG"; printf ''; exit 1; }

OP="${WF_OPERATING_PROMPT:-$HOME/.config/senti/prompts/operating.md}"
OPERATING=""
[ -f "$OP" ] && OPERATING="$(cat "$OP")"

# Downscale the retina screenshot with sips (built-in; no python deps) so the API
# call is fast and cheap: full-res ~3000px/4MB → a 1536px JPEG that keeps on-screen
# text readable. Falls back to the original if sips fails.
SMALL="$WF_RUN/screen-small.jpg"; MIME="image/jpeg"
if ! /usr/bin/sips -Z "${WF_SHOT_PX:-1536}" -s format jpeg "$SHOT" --out "$SMALL" >/dev/null 2>&1; then
  SMALL="$SHOT"; MIME="image/png"   # sips failed → send original PNG, labeled correctly
fi

SENTI_KEY="$KEY" \
SENTI_INSTR="$INSTR" \
SENTI_SHOT="$SMALL" \
SENTI_MODEL="${WF_VISION_MODEL:-gpt-5.6-luna}" \
SENTI_EFFORT="${WF_VISION_EFFORT:-low}" \
SENTI_OPERATING="$OPERATING" \
SENTI_KIND="$KIND" \
SENTI_MIME="$MIME" \
/usr/bin/python3 - <<'PY'
import sys, os, json, base64, urllib.request
key = os.environ["SENTI_KEY"]
instr, kind, mime = os.environ["SENTI_INSTR"], os.environ["SENTI_KIND"], os.environ["SENTI_MIME"]
operating = os.environ["SENTI_OPERATING"]
img = base64.b64encode(open(os.environ["SENTI_SHOT"], "rb").read()).decode()

if kind == "prompt":
    system = ("You are a master prompt engineer with vision. First study the screenshot to "
              "understand WHERE the user is working — the app, the content on screen, and the "
              "task they're in the middle of. You also hear a rough spoken idea. Produce ONE "
              "optimized, high-signal prompt that folds in the relevant on-screen context and "
              "fits what they're doing, ready to paste into a capable LLM. Output ONLY the "
              "finished prompt — no preamble, quotes, code fences, or commentary.\n\n"
              "Behavior layer:\n" + operating)
    utext = "ROUGH IDEA (turn this into the prompt, using the screen for context): " + instr
else:
    system = ("You see a screenshot of the user's current screen (a conversation, document, or "
              "app) and hear a short spoken instruction. Read the on-screen context, then "
              "produce ONLY the text to insert at the user's cursor — a reply, edit, or answer "
              "as the instruction implies. No preamble, quotes, code fences, or commentary.\n\n"
              "Behavior layer:\n" + operating)
    utext = "INSTRUCTION: " + instr

body = json.dumps({
    "model": os.environ["SENTI_MODEL"],
    "reasoning_effort": os.environ["SENTI_EFFORT"],
    "max_completion_tokens": 4000,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": [
            {"type": "text", "text": utext},
            {"type": "image_url", "image_url": {"url": "data:" + mime + ";base64," + img}},
        ]},
    ],
}).encode()
req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
    data=body, headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        sys.stdout.write((json.load(r)["choices"][0]["message"]["content"] or "").strip())
except Exception as e:
    sys.stderr.write("vision error: %s" % e); sys.exit(1)
PY
