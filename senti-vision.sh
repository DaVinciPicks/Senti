#!/bin/bash
# Context mode: read a screenshot of the user's screen + a spoken instruction, and
# produce context-aware text to insert at the cursor (a reply, a prompt, an edit).
#   $1 = spoken instruction (transcribed)
#   $2 = path to the screenshot PNG
# Uses an OpenAI vision model, guided by the reusable operating-prompt layer.
# Prints ONLY the text to insert.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

INSTR="${1:-}"
SHOT="${2:-}"
[ -z "${INSTR// /}" ] && exit 0
[ -f "$SHOT" ] || { printf ''; exit 0; }

KEY=""
[ -f "$WF_OPENAI_KEY" ] && KEY="$(/usr/bin/tr -d '[:space:]\n' < "$WF_OPENAI_KEY")"
[ -z "$KEY" ] && { printf ''; exit 1; }

OPERATING=""
[ -f "$WF_OPERATING_PROMPT" ] && OPERATING="$(cat "$WF_OPERATING_PROMPT")"

/usr/bin/python3 - "$INSTR" "$SHOT" "$KEY" "$WF_VISION_MODEL" "$OPERATING" <<'PY'
import sys, os, json, base64, urllib.request
instr, shot, key, model, operating = sys.argv[1:6]
img = base64.b64encode(open(shot, "rb").read()).decode()
system = ("You see a screenshot of the user's current screen (usually a conversation, "
          "document, or app) and hear a short spoken instruction. Read the on-screen "
          "context, then produce ONLY the text to insert at the user's cursor — a reply, "
          "prompt, edit, or answer as the instruction implies. No preamble, no quotes, "
          "no markdown fences, no meta-commentary.\n\nBehavior layer:\n" + operating)
body = json.dumps({
    "model": model,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": [
            {"type": "text", "text": "INSTRUCTION: " + instr},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}},
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
