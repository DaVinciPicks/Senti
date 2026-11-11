#!/bin/bash
# THE single OpenAI call for every AI mode — text and vision. One caller means the
# request shape, timeout, and error handling can't drift between paths (they did:
# two near-identical python blocks had already diverged to 45s vs 60s timeouts).
#
# Inputs — env first, argv only as a fallback for manual/static invocation:
#   SENTI_SYS   system prompt.   NOT static: embeds session transcripts + vault
#               digests, so it must never touch argv (`ps -Ao args` is readable by
#               every process on the box). Same rule as SENTI_IN.
#   SENTI_IN    the user's dictated text.
#   SENTI_IMG   optional image path → vision request (content array + image_url).
#   SENTI_MIME  image mime, default image/jpeg.
#   SENTI_MODEL / SENTI_EFFORT  overrides; defaults differ by text vs vision.
# senti-selftest.sh runs a canary through BOTH env channels and greps ps for it.
# Prints ONLY the model's text.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
SYS="${SENTI_SYS:-${1:-}}"
USER_MSG="${SENTI_IN:-${2:-}}"

# Behavior layer: prepend the reusable operating prompt so ALL LLM modes run high-level.
# Never touches verbatim dictation (that path never calls this script). Toggle: WF_OPERATING_LAYER=0.
OP="${WF_OPERATING_PROMPT:-$HOME/.config/senti/prompts/operating.md}"
if [ "${WF_OPERATING_LAYER:-1}" = "1" ] && [ -f "$OP" ]; then
  SYS="$(cat "$OP")

--- Task ---
$SYS"
fi

KEYFILE="${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}"
KEY=""
[ -f "$KEYFILE" ] && KEY="$(/usr/bin/tr -d '[:space:]' < "$KEYFILE")"
[ -z "$KEY" ] && { echo "no OpenAI key at $KEYFILE" >>"$WF_LOG"; printf ''; exit 1; }

# Text and vision default to different models/efforts (vision benefits from a little
# reasoning; a rewrite is pure transformation — see config.sh for the measurements).
IMG="${SENTI_IMG:-}"
if [ -n "$IMG" ]; then
  [ -f "$IMG" ] || { echo "image missing: $IMG" >>"$WF_LOG"; printf ''; exit 1; }
  MODEL="${SENTI_MODEL:-${WF_VISION_MODEL:-gpt-6-luna}}"
  EFFORT="${SENTI_EFFORT:-${WF_VISION_EFFORT:-low}}"
else
  MODEL="${SENTI_MODEL:-${WF_TEXT_MODEL:-gpt-6-luna}}"
  EFFORT="${SENTI_EFFORT:-${WF_EFFORT:-none}}"
fi

SENTI_KEY="$KEY" \
SENTI_SYS="$SYS" \
SENTI_USER="$USER_MSG" \
SENTI_IMG="$IMG" \
SENTI_MIME="${SENTI_MIME:-image/jpeg}" \
SENTI_MODEL="$MODEL" \
SENTI_EFFORT="$EFFORT" \
/usr/bin/python3 - <<'PY'
import sys, os, json, base64, urllib.request, urllib.error
key = os.environ["SENTI_KEY"]

img = os.environ.get("SENTI_IMG", "")
if img:
    data = base64.b64encode(open(img, "rb").read()).decode()
    user_content = [
        {"type": "text", "text": os.environ["SENTI_USER"]},
        {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (os.environ["SENTI_MIME"], data)}},
    ]
else:
    user_content = os.environ["SENTI_USER"]

def request(effort):
    body = json.dumps({
        "model": os.environ["SENTI_MODEL"],
        # Reasoning tier. Text default is 'none': on the prompt-rewrite task it measured
        # 2.2x cheaper and 1.8x faster than 'low' at an identical eval score. Some models
        # (gpt-6.1-sol, gpt-6-astra, checked 2026-11-11) reject 'none'; see the retry below.
        "reasoning_effort": effort,
        # Reasoning tokens count against this ceiling: leave headroom or output comes back empty.
        "max_completion_tokens": 4000,
        "messages": [
            {"role": "system", "content": os.environ["SENTI_SYS"]},
            {"role": "user", "content": user_content},
        ],
    }).encode()
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
        data=body, headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["choices"][0]["message"]["content"] or ""

effort = os.environ["SENTI_EFFORT"]
for attempt in (1, 2):
    try:
        sys.stdout.write(request(effort))
        break
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = json.load(e).get("error", {}).get("message", "")[:200]
        except Exception:
            pass
        # A model that doesn't accept 'none' says so in a 400; try once more at 'low'.
        if attempt == 1 and e.code == 400 and effort == "none" and "reasoning_effort" in detail:
            effort = "low"
            continue
        sys.stderr.write("openai error: HTTP %s for model %s: %s\n" % (e.code, os.environ["SENTI_MODEL"], detail)); sys.exit(1)
    except Exception as e:
        sys.stderr.write("openai error: %s\n" % e); sys.exit(1)
PY
