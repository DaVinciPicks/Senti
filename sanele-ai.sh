#!/bin/bash
# THE single OpenAI call for every AI mode — text and vision. One caller means the
# request shape, timeout, and error handling can't drift between paths (they did:
# two near-identical python blocks had already diverged to 45s vs 60s timeouts).
#
# Inputs — env first, argv only as a fallback for manual/static invocation:
#   SANELE_SYS   system prompt.   NOT static: embeds session transcripts + vault
#               digests, so it must never touch argv (`ps -Ao args` is readable by
#               every process on the box). Same rule as SANELE_IN.
#   SANELE_IN    the user's dictated text.
#   SANELE_IMG   optional image path → vision request (content array + image_url).
#   SANELE_MIME  image mime, default image/jpeg.
#   SANELE_MODEL / SANELE_EFFORT  overrides; defaults differ by text vs vision.
# sanele-selftest.sh runs a canary through BOTH env channels and greps ps for it.
# Prints ONLY the model's text.
set -uo pipefail
source "$HOME/.config/sanele/config.sh"
SYS="${SANELE_SYS:-${1:-}}"
USER_MSG="${SANELE_IN:-${2:-}}"

# Behavior layer: prepend the reusable operating prompt so ALL LLM modes run high-level.
# Never touches verbatim dictation (that path never calls this script). Toggle: WF_OPERATING_LAYER=0.
OP="${WF_OPERATING_PROMPT:-$HOME/.config/sanele/prompts/operating.md}"
if [ "${WF_OPERATING_LAYER:-1}" = "1" ] && [ -f "$OP" ]; then
  SYS="$(cat "$OP")

--- Task ---
$SYS"
fi

KEYFILE="${WF_OPENAI_KEY:-$HOME/.config/sanele/openai-key}"
KEY=""
[ -f "$KEYFILE" ] && KEY="$(/usr/bin/tr -d '[:space:]' < "$KEYFILE")"
[ -z "$KEY" ] && { echo "no OpenAI key at $KEYFILE" >>"$WF_LOG"; printf ''; exit 1; }

# Text and vision default to different models/efforts (vision benefits from a little
# reasoning; a rewrite is pure transformation — see config.sh for the measurements).
IMG="${SANELE_IMG:-}"
if [ -n "$IMG" ]; then
  [ -f "$IMG" ] || { echo "image missing: $IMG" >>"$WF_LOG"; printf ''; exit 1; }
  MODEL="${SANELE_MODEL:-${WF_VISION_MODEL:-gpt-5.6-luna}}"
  EFFORT="${SANELE_EFFORT:-${WF_VISION_EFFORT:-low}}"
else
  MODEL="${SANELE_MODEL:-${WF_TEXT_MODEL:-gpt-5.6-luna}}"
  EFFORT="${SANELE_EFFORT:-${WF_EFFORT:-none}}"
fi

SANELE_KEY="$KEY" \
SANELE_SYS="$SYS" \
SANELE_USER="$USER_MSG" \
SANELE_IMG="$IMG" \
SANELE_MIME="${SANELE_MIME:-image/jpeg}" \
SANELE_MODEL="$MODEL" \
SANELE_EFFORT="$EFFORT" \
/usr/bin/python3 - <<'PY'
import sys, os, json, base64, urllib.request
key = os.environ["SANELE_KEY"]

img = os.environ.get("SANELE_IMG", "")
if img:
    data = base64.b64encode(open(img, "rb").read()).decode()
    user_content = [
        {"type": "text", "text": os.environ["SANELE_USER"]},
        {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (os.environ["SANELE_MIME"], data)}},
    ]
else:
    user_content = os.environ["SANELE_USER"]

body = json.dumps({
    "model": os.environ["SANELE_MODEL"],
    # gpt-5.x reasoning tier: 'none'|'low'|'medium'|'high'|'xhigh' ('minimal' is rejected).
    # Text default is 'none': on the prompt-rewrite task it measured 2.2x cheaper and 1.8x
    # faster than 'low' at an identical eval score. sanele-judge.sh overrides to 'low'.
    "reasoning_effort": os.environ["SANELE_EFFORT"],
    # Reasoning tokens count against this ceiling — leave headroom or output comes back empty.
    "max_completion_tokens": 4000,
    "messages": [
        {"role": "system", "content": os.environ["SANELE_SYS"]},
        {"role": "user", "content": user_content},
    ],
}).encode()
req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
    data=body, headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        sys.stdout.write(json.load(r)["choices"][0]["message"]["content"] or "")
except Exception as e:
    sys.stderr.write("openai error: %s" % e); sys.exit(1)
PY
