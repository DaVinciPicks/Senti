#!/bin/bash
# Senti installer — deploys the local dictation system from this repo.
# Idempotent; safe to re-run after `git pull`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/senti"
LA="$HOME/Library/LaunchAgents"
mkdir -p "$CFG" "$HOME/.cache/senti" "$HOME/Library/Logs" "$LA" "$HOME/Applications"

echo "→ scripts, config, dictionary, prompts"
# Scripts are code — always update.
cp "$HERE"/senti-*.sh "$CFG"/
chmod +x "$CFG"/senti-*.sh
mkdir -p "$CFG/prompts"; cp "$HERE"/prompts/*.md "$CFG/prompts/" 2>/dev/null || true
# Model-aware prompting knowledge base — code, always update.
mkdir -p "$CFG/prompts/models"; cp "$HERE"/prompts/models/*.md "$CFG/prompts/models/" 2>/dev/null || true
# Eval cases are user-tunable — install only if missing.
mkdir -p "$CFG/eval"; [ -f "$CFG/eval/cases.txt" ] || cp "$HERE/eval/cases.txt" "$CFG/eval/" 2>/dev/null || true
# The dictionary is user-tunable — install only if missing.
[ -f "$CFG/replacements.txt" ] || cp "$HERE/replacements.txt" "$CFG/"

# config.sh is user-tunable, so it installs only-if-missing and a re-run never
# clobbers local tuning. But that means a stale config can silently pin retired
# settings (e.g. an old vision model) and make an upgrade a no-op. WF_CONFIG_VERSION
# guards that: on a schema bump we back the old file up rather than keep it.
# NB: `|| true` is load-bearing — under `set -e -o pipefail`, grep finding nothing
# (which is exactly the case for a pre-versioning config.sh) would abort the install.
repo_ver()  { { /usr/bin/grep -E '^WF_CONFIG_VERSION=' "$1" 2>/dev/null || true; } | head -1 | cut -d= -f2 | tr -d '[:space:]'; }
is_num()    { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if [ ! -f "$CFG/config.sh" ]; then
  cp "$HERE/config.sh" "$CFG/"
else
  HAVE="$(repo_ver "$CFG/config.sh")"; WANT="$(repo_ver "$HERE/config.sh")"
  is_num "$HAVE" || HAVE=0
  is_num "$WANT" || WANT=0
  if [ "$HAVE" -lt "$WANT" ]; then
    cp "$CFG/config.sh" "$CFG/config.sh.bak"
    cp "$HERE/config.sh" "$CFG/config.sh"
    echo "  ! config.sh schema v$HAVE → v$WANT: yours saved to config.sh.bak"
    echo "    (re-apply any personal tuning from the .bak — model IDs are no longer set there)"
  fi
fi

echo "→ microphone-permission helper (Swift/AVFoundation)"
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$HERE/senti-mic-auth.swift" -o "$CFG/senti-mic-auth" \
    -framework AVFoundation -framework Foundation
else
  echo "  warning: swiftc not found (install Xcode CLT) — mic helper not built"
fi

echo "→ Hammerspoon config"
mkdir -p "$HOME/.hammerspoon"
cp "$HERE/senti.lua" "$HOME/.hammerspoon/init.lua"

echo "→ warm-whisper launchd service"
launchctl unload "$LA/com.leo.senti.plist" 2>/dev/null || true
sed "s|__HOME__|$HOME|g" "$HERE/com.leo.senti.plist" > "$LA/com.leo.senti.plist"
launchctl load "$LA/com.leo.senti.plist"

echo "→ icons (vector → resvg → iconutil)"
bash "$HERE/app/make-icon.sh"

echo "→ Senti.app (menu-bar launcher)"
APP="$HOME/Applications/Senti.app"; rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/app/launcher.sh" "$APP/Contents/MacOS/senti"; chmod +x "$APP/Contents/MacOS/senti"
[ -f "$CFG/appicon.icns" ] && cp "$CFG/appicon.icns" "$APP/Contents/Resources/appicon.icns"
# Nudge Finder/Dock to drop the cached old icon.
touch "$APP" 2>/dev/null || true

echo ""
echo "✅ Senti installed."
echo "   1) Open Hammerspoon (or run: open -a Hammerspoon) — grant Accessibility if asked."
echo "   2) Menu bar 🎤 → Grant / test microphone → click Allow."
echo "   3) Hold right ⌥ and speak. AI modes need an OpenAI key at $CFG/openai-key."
