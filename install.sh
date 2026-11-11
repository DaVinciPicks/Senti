#!/bin/bash
# Senti installer — deploys the local dictation system from this repo.
# Idempotent; safe to re-run after `git pull`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/senti"
LA="$HOME/Library/LaunchAgents"

# --- one-time migration: Sanele → Senti -----------------------------------------
# The project was renamed Senti → Sanele (2026-08-19), then back to Senti (2026-10-17).
# A Sanele install keeps the user's API key, dictionary, vault map and eval cases
# under ~/.config/sanele; move them across rather than stranding them. MUST run
# before the mkdir below — once "$CFG" exists the "not already migrated" test can
# never fire again.
OLDCFG="$HOME/.config/sanele"
OLDCACHE="$HOME/.cache/sanele"
if [ -d "$OLDCFG" ] && [ ! -d "$CFG" ]; then
  echo "→ migrating ~/.config/sanele → ~/.config/senti"
  mv "$OLDCFG" "$CFG"
fi
if [ -d "$OLDCACHE" ] && [ ! -d "$HOME/.cache/senti" ]; then
  mv "$OLDCACHE" "$HOME/.cache/senti"
fi
# Drop the old-generation scripts so the dir can't hold both names at once.
rm -f "$CFG"/sanele-*.sh "$CFG/sanele-mic-auth" 2>/dev/null || true
# Unload every old launchd label (Sanele's, and the first Senti's), or two
# whisper-servers race for the same port.
for old in io.sanele.server com.leo.senti; do
  if [ -f "$LA/$old.plist" ]; then
    launchctl unload "$LA/$old.plist" 2>/dev/null || true
    rm -f "$LA/$old.plist"
  fi
done
rm -rf "$HOME/Applications/Sanele.app"
# A first-generation Senti install left its own senti*.log behind, so the new name can
# already be taken. Keep that older log under another name rather than skipping the move.
for suffix in "" "-server"; do
  OLDLOG="$HOME/Library/Logs/sanele$suffix.log"; NEWLOG="$HOME/Library/Logs/senti$suffix.log"
  if [ -f "$OLDLOG" ]; then
    [ -f "$NEWLOG" ] && mv "$NEWLOG" "$HOME/Library/Logs/senti$suffix.pre-sanele.log"
    mv "$OLDLOG" "$NEWLOG"
  fi
done
# --------------------------------------------------------------------------------

mkdir -p "$CFG" "$HOME/.cache/senti" "$HOME/Library/Logs" "$LA" "$HOME/Applications"
# ~/.config/senti holds the API key (600) plus your dictionary, vault map, and prompt
# KB. Tighten the dir itself to 700 so nothing here is world-readable — defense in
# depth even though the key file is already 600.
chmod 700 "$CFG" "$HOME/.cache/senti" 2>/dev/null || true

echo "→ scripts, config, dictionary, prompts"
# Scripts are code — always update.
cp "$HERE"/senti-*.sh "$CFG"/
chmod +x "$CFG"/senti-*.sh
mkdir -p "$CFG/prompts"; cp "$HERE"/prompts/*.md "$CFG/prompts/" 2>/dev/null || true
# Model-aware prompting knowledge base — code, always update.
mkdir -p "$CFG/prompts/models"; cp "$HERE"/prompts/models/*.md "$CFG/prompts/models/" 2>/dev/null || true
# Both copies above are `|| true`, so a missing prompts/ (a copy of the repo with the KB
# split out, see CLAUDE.md) would fail silently and the AI modes would run with no craft
# layer and no model guidance while still looking fine. Say so loudly instead.
# Check the SOURCE, not the deployed copy: the previous install's files would keep
# this check quiet while KB updates stop.
if [ ! -f "$HERE/prompts/models/_techniques.md" ]; then
  echo "  ! no prompting knowledge base in $HERE/prompts — AI modes will run WITHOUT model guidance."
fi
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
    # One backup per version: a single .bak slot was overwritten by the next bump, so
    # tuning never re-applied from an older backup was lost for good.
    cp "$CFG/config.sh" "$CFG/config.sh.v$HAVE.bak"
    cp "$HERE/config.sh" "$CFG/config.sh"
    echo "  ! config.sh schema v$HAVE → v$WANT: yours saved to config.sh.v$HAVE.bak"
    echo "    (re-apply any personal tuning from the .bak — model IDs are no longer set there)"
  fi
fi

echo "→ microphone-permission helper (Swift/AVFoundation)"
# Never let this abort the install: under set -e a failed build (an SDK mismatch after a
# macOS update) used to stop here with new scripts deployed and the old init.lua still
# pointing at them. senti.lua copes with a missing helper.
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$HERE/senti-mic-auth.swift" -o "$CFG/senti-mic-auth" \
    -framework AVFoundation -framework Foundation \
    || echo "  warning: mic helper failed to build — permission prompts will not appear"
else
  echo "  warning: swiftc not found (install Xcode CLT) — mic helper not built"
fi

echo "→ Hammerspoon config"
mkdir -p "$HOME/.hammerspoon"
# init.lua is the whole Hammerspoon config. If it is someone's own (no Senti marker),
# keep a copy instead of silently replacing it.
HSINIT="$HOME/.hammerspoon/init.lua"
if [ -f "$HSINIT" ] && ! /usr/bin/grep -q 'wf.armTap' "$HSINIT"; then
  cp "$HSINIT" "$HSINIT.pre-senti"
  echo "  ! your existing init.lua was saved as init.lua.pre-senti"
fi
cp "$HERE/senti.lua" "$HSINIT"

echo "→ warm-whisper launchd service"
launchctl unload "$LA/io.senti.server.plist" 2>/dev/null || true
sed "s|__HOME__|$HOME|g" "$HERE/io.senti.server.plist" > "$LA/io.senti.server.plist"
launchctl load "$LA/io.senti.server.plist" \
  || echo "  ! launchctl load failed — run: launchctl bootstrap gui/$(id -u) $LA/io.senti.server.plist"

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

# Keep a Desktop copy in sync IF one exists. Deliberately not created here — an
# installer that writes to someone's Desktop uninvited is rude — but once it is
# there it must track the real app, or it keeps launching an old build with a
# stale icon. Create it with:  cp -R ~/Applications/Senti.app ~/Desktop/
# A Desktop launcher under the old name points at a launchd label that no longer
# exists, so double-clicking it quits Hammerspoon and cannot bring it back. Having
# one means the user wants a Desktop copy, so it becomes a copy of the new app.
DESKAPP="$HOME/Desktop/Senti.app"
OLDDESKAPP="$HOME/Desktop/Sanele.app"
if [ -d "$DESKAPP" ] || [ -d "$OLDDESKAPP" ]; then
  rm -rf "$DESKAPP" "$OLDDESKAPP"; cp -R "$APP" "$DESKAPP"; touch "$DESKAPP" 2>/dev/null || true
  echo "  ✓ Desktop copy refreshed"
fi

echo ""
echo "✅ Senti installed."
echo "   1) Open Hammerspoon (or run: open -a Hammerspoon) — grant Accessibility if asked."
echo "   2) Menu bar S → Grant / test microphone → click Allow."
echo "   3) Hold right ⌥ and speak. AI modes need an OpenAI key at $CFG/openai-key."
