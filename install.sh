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
# config.sh and the dictionary are user-tunable — install only if missing so a
# re-run / `git pull` never clobbers local edits.
[ -f "$CFG/config.sh" ]       || cp "$HERE/config.sh" "$CFG/"
[ -f "$CFG/replacements.txt" ] || cp "$HERE/replacements.txt" "$CFG/"

echo "→ microphone-permission helper (Swift/AVFoundation)"
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$HERE/senti-mic-auth.swift" -o "$CFG/senti-mic-auth" \
    -framework AVFoundation -framework Foundation
else
  echo "  warning: swiftc not found (install Xcode CLT) — mic helper not built"
fi

echo "→ migrating secrets/prefs from any prior install"
OLD="$HOME/.config/whisper-flow"
for f in deepseek-key api-key model.pref; do
  if [ -f "$OLD/$f" ] && [ ! -f "$CFG/$f" ]; then cp "$OLD/$f" "$CFG/$f"; chmod 600 "$CFG/$f" || true; fi
done

echo "→ Hammerspoon config"
mkdir -p "$HOME/.hammerspoon"
cp "$HERE/senti.lua" "$HOME/.hammerspoon/init.lua"

echo "→ warm-whisper launchd service"
launchctl unload "$LA/com.leo.senti.plist" 2>/dev/null || true
sed "s|__HOME__|$HOME|g" "$HERE/com.leo.senti.plist" > "$LA/com.leo.senti.plist"
launchctl load "$LA/com.leo.senti.plist"

echo "→ Senti.app (menu-bar launcher)"
APP="$HOME/Applications/Senti.app"; rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/app/launcher.sh" "$APP/Contents/MacOS/senti"; chmod +x "$APP/Contents/MacOS/senti"
if command -v python3 >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  python3 "$HERE/app/make-icon.py" >/dev/null 2>&1 || true
  [ -d "$CFG/appicon.iconset" ] && iconutil -c icns "$CFG/appicon.iconset" \
    -o "$APP/Contents/Resources/appicon.icns" 2>/dev/null || true
fi

echo ""
echo "✅ Senti installed."
echo "   1) Open Hammerspoon (or run: open -a Hammerspoon) — grant Accessibility if asked."
echo "   2) Menu bar 🎤 → Grant / test microphone → click Allow."
echo "   3) Hold right ⌥ and speak. Drop a DeepSeek key in $CFG/deepseek-key for AI modes."
