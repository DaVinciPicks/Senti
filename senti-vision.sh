#!/bin/bash
# Vision mode: read a screenshot of the user's screen + a spoken instruction.
#   $1 = spoken instruction (transcribed)
#   $2 = path to the screenshot PNG
#   $3 = kind: "context" (draft reply/edit at cursor) | "prompt" (generate an
#        optimized prompt that folds in the on-screen working context)
# Uses an OpenAI vision model, guided by the reusable operating-prompt layer.
# Prints ONLY the text to insert.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

INSTR="${1:-}"
SHOT="${2:-}"
KIND="${3:-context}"
[ -z "${INSTR// /}" ] && exit 0
[ -f "$SHOT" ] || { printf ''; exit 0; }

KEY=""
[ -f "$WF_OPENAI_KEY" ] && KEY="$(/usr/bin/tr -d '[:space:]\n' < "$WF_OPENAI_KEY")"
[ -z "$KEY" ] && { printf ''; exit 1; }

OPERATING=""
[ -f "$WF_OPERATING_PROMPT" ] && OPERATING="$(cat "$WF_OPERATING_PROMPT")"

# Downscale the retina screenshot with sips (built-in; no python deps) so the API
# call is fast and cheap: full-res ~3000px/4MB → a 1536px JPEG that keeps on-screen
# text readable. Falls back to the original if sips fails.
SMALL="$WF_RUN/screen-small.jpg"
/usr/bin/sips -Z 1536 -s format jpeg "$SHOT" --out "$SMALL" >/dev/null 2>&1 || SMALL="$SHOT"

/usr/bin/python3 - "$INSTR" "$SMALL" "$KEY" "$WF_VISION_MODEL" "$OPERATING" "$KIND" <<'PY'
import sys, json, base64, urllib.request
instr, shot, key, model, operating, kind = sys.argv[1:7]
img = base64.b64encode(open(shot, "rb").read()).decode()
mime = "image/jpeg"

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
    "model": model,
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
        sys.stdout.write(json.load(r)["choices"][0]["message"]["content"].strip())
except Exception as e:
    sys.stderr.write("vision error: %s" % e); sys.exit(1)
PY
