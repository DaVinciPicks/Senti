#!/bin/bash
# Double-click to toggle Senti on/off.
PLIST="$HOME/Library/LaunchAgents/io.senti.server.plist"

if /usr/bin/pgrep -x Hammerspoon >/dev/null 2>&1; then
  # --- Turn OFF ---
  /usr/bin/osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1
  /usr/bin/osascript -e 'display notification "Dictation hotkeys off. The local engine stays warm." with title "Senti is off"'
else
  # --- Turn ON ---
  /bin/launchctl load "$PLIST" 2>/dev/null           # ensure warm whisper engine
  /usr/bin/open -a Hammerspoon                        # load dictation hotkeys
  /usr/bin/osascript -e 'display notification "Hold right Option (⌥) to dictate, or right Command (⌘) for Prompt mode. Senti is in the menu bar." with title "Senti is on"'
fi
