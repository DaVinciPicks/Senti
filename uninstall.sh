#!/bin/bash
# Senti uninstaller: removes what install.sh put on this Mac, after asking.
#   ./uninstall.sh            asks before each step (the default answer is always No)
#   ./uninstall.sh --yes      removes Senti itself without asking; keeps your settings,
#                             API keys and speech models
#   ./uninstall.sh --yes --all   also removes settings, keys and speech models
#
# What "Senti itself" means here, all of it written by install.sh:
#   ~/Library/LaunchAgents/io.senti.server.plist   the warm whisper server (stopped first)
#   ~/.hammerspoon/init.lua                        restored from the newest
#                                                  init.lua.pre-senti.* backup, if any
#   ~/Applications/Senti.app (and ~/Desktop/Senti.app if you made that copy)
#   ~/.cache/senti                                 audio, screenshots, session memory
#   ~/Library/Logs/senti.log, senti-server.log
# Asked separately:
#   ~/.config/senti plus the io.senti items in your macOS Keychain (your API keys)
#   ~/.local/share/whisper-models                  the speech models (other tools may use them)
# Never touched: Homebrew and the packages it installed (whisper-cpp, sox, resvg,
# Hammerspoon). The last lines print the command to remove those if you want to.
#
# Answers are read from the terminal (or a pipe). With no input at all, every answer is No
# and nothing changes.
set -uo pipefail
ASSUME_YES=0; ALL=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    --all) ALL=1 ;;
    -h|--help) /usr/bin/sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

CFG="$HOME/.config/senti"
PLIST="$HOME/Library/LaunchAgents/io.senti.server.plist"
HSDIR="$HOME/.hammerspoon"
MODELS="$HOME/.local/share/whisper-models"
LAUNCHCTL="${SENTI_LAUNCHCTL:-launchctl}"   # tests point this at a logging stub

ask() {   # ask "question" → 0 for yes. Default No. Reads one line of input.
  local reply
  printf '%s [y/N] ' "$1"
  IFS= read -r reply || reply=""
  [ -t 0 ] || echo "$reply"
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
confirm_main() { [ "$ASSUME_YES" = 1 ] && return 0; ask "$1"; }
confirm_extra() {
  if [ "$ASSUME_YES" = 1 ]; then [ "$ALL" = 1 ]; return; fi
  ask "$1"
}

echo "This removes Senti from this Mac:"
[ -f "$PLIST" ] && echo "  - the whisper server LaunchAgent (stopped first)"
[ -f "$HSDIR/init.lua" ] && echo "  - Senti's Hammerspoon config (your previous init.lua comes back if a backup exists)"
[ -d "$HOME/Applications/Senti.app" ] && echo "  - ~/Applications/Senti.app"
[ -d "$HOME/.cache/senti" ] && echo "  - ~/.cache/senti (audio, screenshots, session memory)"
echo "  - Senti's logs in ~/Library/Logs"
if ! confirm_main "Remove Senti?"; then
  echo "Nothing was changed."
  exit 0
fi

# 1. Stop the server before removing its plist, or launchd keeps it running.
if [ -f "$PLIST" ]; then
  "$LAUNCHCTL" bootout "gui/$(id -u)/io.senti.server" >/dev/null 2>&1 \
    || "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "✓ stopped and removed the whisper server LaunchAgent"
fi

# 2. Hammerspoon config: the newest backup install.sh made comes back as init.lua.
#    Backup names sort by time (init.lua.pre-senti.YYYYMMDD-HHMMSS).
NEWEST=""
for b in "$HSDIR"/init.lua.pre-senti.*; do
  [ -f "$b" ] && NEWEST="$b"
done
if [ -n "$NEWEST" ]; then
  mv -f "$NEWEST" "$HSDIR/init.lua"
  echo "✓ restored your previous Hammerspoon config from $(basename "$NEWEST")"
elif [ -f "$HSDIR/init.lua" ] && /usr/bin/grep -q 'wf.armTap' "$HSDIR/init.lua"; then
  rm -f "$HSDIR/init.lua"
  echo "✓ removed Senti's Hammerspoon config (there was no earlier config to restore)"
fi

# 3. The app, the cache (it holds audio and screenshots while a turn runs) and the logs.
rm -rf "$HOME/Applications/Senti.app" "$HOME/Desktop/Senti.app"
rm -rf "$HOME/.cache/senti"
rm -f "$HOME/Library/Logs/senti.log" "$HOME/Library/Logs/senti-server.log"
echo "✓ removed Senti.app, ~/.cache/senti and the logs"

# 4. Settings and keys: asked separately, kept by default.
if [ -d "$CFG" ]; then
  if confirm_extra "Also remove your settings and API keys (~/.config/senti and the io.senti Keychain items)?"; then
    if [ -f "$CFG/senti-key.sh" ]; then
      for p in openai anthropic openrouter; do
        bash "$CFG/senti-key.sh" clear "$p" >/dev/null 2>&1 || echo "  ! could not clear the $p Keychain item (Keychain locked?)"
      done
    fi
    rm -rf "$CFG"
    echo "✓ removed ~/.config/senti and Senti's Keychain items"
  else
    echo "  kept ~/.config/senti and your keys"
  fi
fi

# 5. Speech models: other whisper tools may share this folder, so ask.
if [ -d "$MODELS" ]; then
  SIZE="$(/usr/bin/du -sh "$MODELS" 2>/dev/null | cut -f1)"
  if confirm_extra "Also remove the speech models (~/.local/share/whisper-models, ${SIZE:-unknown size})?"; then
    rm -rf "$MODELS"
    echo "✓ removed the speech models"
  else
    echo "  kept the speech models"
  fi
fi

echo ""
echo "Senti is removed. Hammerspoon is still running the old config until you reload it or quit it."
echo "Homebrew packages were left in place. To remove them too:"
echo "  brew uninstall whisper-cpp sox resvg && brew uninstall --cask hammerspoon"
