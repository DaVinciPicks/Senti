#!/bin/bash
# Shared AI text call for prompt & command modes.
#   $1 = system prompt   $2 = user message
# Engine: OpenAI gpt-5.4-mini (fast reasoning tier). Prints ONLY the model's text.
#
# The prompt and the user's dictated text are passed via ENV, never argv — argv is
# world-readable in `ps`, and the user's speech is the whole thing we're protecting.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
SYS="${1:-}"
# The user's dictated text arrives in SENTI_IN, NOT argv. `ps -Ao args` is readable by
# every process on the box, so anything on a command line is effectively public — and
# the speech is the one thing this app exists to protect. $2 is kept only as a fallback
# for manual invocation; callers must use SENTI_IN. senti-selftest.sh asserts this.
USER_MSG="${SENTI_IN:-${2:-}}"

# Behavior layer: prepend the reusable operating prompt so BOTH LLM modes run high-level.
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

SENTI_KEY="$KEY" \
SENTI_SYS="$SYS" \
SENTI_USER="$USER_MSG" \
SENTI_MODEL="${WF_TEXT_MODEL:-gpt-5.6-luna}" \
SENTI_EFFORT="${WF_EFFORT:-none}" \
/usr/bin/python3 - <<'PY'
import sys, os, json, urllib.request
key = os.environ["SENTI_KEY"]
body = json.dumps({
    "model": os.environ["SENTI_MODEL"],
    # gpt-5.x reasoning tier: 'none'|'low'|'medium'|'high'|'xhigh' ('minimal' is rejected).
    # Default is 'none': on the prompt-rewrite task it measured 2.2x cheaper and 1.8x
    # faster than 'low' at an identical 8.00 eval score. senti-judge.sh overrides to 'low'.
    "reasoning_effort": os.environ["SENTI_EFFORT"],
    # Reasoning tokens count against this ceiling — leave headroom or output comes back empty.
    "max_completion_tokens": 4000,
    "messages": [
        {"role": "system", "content": os.environ["SENTI_SYS"]},
        {"role": "user", "content": os.environ["SENTI_USER"]},
    ],
}).encode()
req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
    data=body, headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=45) as r:
        sys.stdout.write(json.load(r)["choices"][0]["message"]["content"] or "")
except Exception as e:
    sys.stderr.write("openai error: %s" % e); sys.exit(1)
PY
