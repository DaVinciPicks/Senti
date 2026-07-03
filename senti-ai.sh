#!/bin/bash
# Shared AI text call for prompt & command modes.
#   $1 = system prompt   $2 = user message
# Engine: DeepSeek (fast, cheap) if a key exists, else the local claude CLI.
# Prints ONLY the model's text response.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
SYS="${1:-}"
USER_MSG="${2:-}"

# Behavior layer: prepend the reusable operating prompt so BOTH LLM modes (prompt +
# command) run at a consistently high level. This never touches verbatim dictation —
# that path is pure Whisper and never calls this script. Toggle: WF_OPERATING_LAYER=0.
if [ "${WF_OPERATING_LAYER:-1}" = "1" ] && [ -f "$WF_OPERATING_PROMPT" ]; then
  SYS="$(cat "$WF_OPERATING_PROMPT")

--- Task ---
$SYS"
fi

DS_KEY=""
[ -f "$WF_DEEPSEEK_KEY" ] && DS_KEY="$(/usr/bin/tr -d '[:space:]\n' < "$WF_DEEPSEEK_KEY")"

if [ -n "$DS_KEY" ]; then
  # DeepSeek — OpenAI-compatible. Python builds/parses JSON so any quotes or
  # newlines in the selected text are escaped safely.
  /usr/bin/python3 - "$SYS" "$USER_MSG" "$DS_KEY" "$WF_DEEPSEEK_MODEL" <<'PY'
import sys, json, urllib.request
sysmsg, usermsg, key, model = sys.argv[1:5]
body = json.dumps({
    "model": model, "temperature": 0, "stream": False,
    "messages": [{"role": "system", "content": sysmsg},
                 {"role": "user", "content": usermsg}],
}).encode()
req = urllib.request.Request("https://api.deepseek.com/chat/completions",
    data=body, headers={"Authorization": "Bearer " + key,
                        "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        sys.stdout.write(json.load(r)["choices"][0]["message"]["content"])
except Exception as e:
    sys.stderr.write("deepseek error: %s" % e)
    sys.exit(1)
PY
  exit $?
fi

# Fallback: local claude CLI (OAuth, slower; --bare if an Anthropic key is set).
CLAUDE_BIN="${WF_CLAUDE:-$HOME/.local/bin/claude}"
[ -x "$CLAUDE_BIN" ] || { printf ''; exit 1; }
BARE=(); [ -n "${ANTHROPIC_API_KEY:-}" ] && BARE=(--bare)
"$CLAUDE_BIN" -p "$USER_MSG" --append-system-prompt "$SYS" \
  --model "${WF_COMMAND_MODEL:-claude-haiku-4-5-20251001}" \
  ${BARE[@]+"${BARE[@]}"}
