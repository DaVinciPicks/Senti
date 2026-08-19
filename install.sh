#!/bin/bash
# Sanele installer — deploys the local dictation system from this repo.
# Idempotent; safe to re-run after `git pull`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/sanele"
LA="$HOME/Library/LaunchAgents"

# --- one-time migration: Senti → Sanele -----------------------------------------
# The project was renamed. A pre-rename install keeps the user's API key, dictionary,
# vault map and eval cases under ~/.config/senti; move them across rather than
# stranding them. MUST run before the mkdir below — once "$CFG" exists the
# "not already migrated" test can never fire again.
OLDCFG="$HOME/.config/senti"
OLDCACHE="$HOME/.cache/senti"
if [ -d "$OLDCFG" ] && [ ! -d "$CFG" ]; then
  echo "→ migrating ~/.config/senti → ~/.config/sanele"
  mv "$OLDCFG" "$CFG"
fi
if [ -d "$OLDCACHE" ] && [ ! -d "$HOME/.cache/sanele" ]; then
  mv "$OLDCACHE" "$HOME/.cache/sanele"
fi
# Drop the old-generation scripts so the dir can't hold both names at once.
rm -f "$CFG"/senti-*.sh "$CFG/senti-mic-auth" 2>/dev/null || true
# Unload the old launchd label, or two whisper-servers race for the same port.
if [ -f "$LA/com.leo.senti.plist" ]; then
  launchctl unload "$LA/com.leo.senti.plist" 2>/dev/null || true
  rm -f "$LA/com.leo.senti.plist"
fi
rm -rf "$HOME/Applications/Senti.app"
if [ -f "$HOME/Library/Logs/senti.log" ] && [ ! -f "$HOME/Library/Logs/sanele.log" ]; then
  mv "$HOME/Library/Logs/senti.log" "$HOME/Library/Logs/sanele.log"
fi
# --------------------------------------------------------------------------------

mkdir -p "$CFG" "$HOME/.cache/sanele" "$HOME/Library/Logs" "$LA" "$HOME/Applications"
# ~/.config/sanele holds the API key (600) plus your dictionary, vault map, and prompt
# KB. Tighten the dir itself to 700 so nothing here is world-readable — defense in
# depth even though the key file is already 600.
chmod 700 "$CFG" "$HOME/.cache/sanele" 2>/dev/null || true

echo "→ scripts, config, dictionary, prompts"
# Scripts are code — always update.
cp "$HERE"/sanele-*.sh "$CFG"/
chmod +x "$CFG"/sanele-*.sh
mkdir -p "$CFG/prompts"; cp "$HERE"/prompts/*.md "$CFG/prompts/" 2>/dev/null || true
# Model-aware prompting knowledge base — code, always update.
mkdir -p "$CFG/prompts/models"; cp "$HERE"/prompts/models/*.md "$CFG/prompts/models/" 2>/dev/null || true
# Eval cases are user-tunable — install only if missing.
mkdir -p "$CFG/eval"; [ -f "$CFG/eval/cases.txt" ] || cp "$HERE/eval/cases.txt" "$CFG/eval/" 2>/dev/null || true
# The dictionary and the vault map are user-tunable — install only if missing.
[ -f "$CFG/replacements.txt" ] || cp "$HERE/replacements.txt" "$CFG/"
[ -f "$CFG/brain-map.txt" ]    || cp "$HERE/brain-map.txt" "$CFG/"

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
  swiftc -O "$HERE/sanele-mic-auth.swift" -o "$CFG/sanele-mic-auth" \
    -framework AVFoundation -framework Foundation
else
  echo "  warning: swiftc not found (install Xcode CLT) — mic helper not built"
fi

echo "→ Hammerspoon config"
mkdir -p "$HOME/.hammerspoon"
cp "$HERE/sanele.lua" "$HOME/.hammerspoon/init.lua"

echo "→ warm-whisper launchd service"
launchctl unload "$LA/io.sanele.server.plist" 2>/dev/null || true
sed "s|__HOME__|$HOME|g" "$HERE/io.sanele.server.plist" > "$LA/io.sanele.server.plist"
launchctl load "$LA/io.sanele.server.plist"

echo "→ icons (vector → resvg → iconutil)"
bash "$HERE/app/make-icon.sh"

echo "→ Sanele.app (menu-bar launcher)"
APP="$HOME/Applications/Sanele.app"; rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/app/launcher.sh" "$APP/Contents/MacOS/sanele"; chmod +x "$APP/Contents/MacOS/sanele"
[ -f "$CFG/appicon.icns" ] && cp "$CFG/appicon.icns" "$APP/Contents/Resources/appicon.icns"
# Nudge Finder/Dock to drop the cached old icon.
touch "$APP" 2>/dev/null || true

echo ""
echo "✅ Sanele installed."
echo "   1) Open Hammerspoon (or run: open -a Hammerspoon) — grant Accessibility if asked."
echo "   2) Menu bar 🎤 → Grant / test microphone → click Allow."
echo "   3) Hold right ⌥ and speak. AI modes need an OpenAI key at $CFG/openai-key."
