-- ═══════════════════════════════════════════════════════════════════════
--  Senti — free, 100% local speech-to-text (a Wispr Flow clone)
--  Audio is recorded locally, transcribed by a local whisper.cpp server on
--  127.0.0.1, and never leaves this Mac.
--
--  Everything lives on the global `wf` table on purpose: Hammerspoon does NOT
--  retain hs.eventtap objects, so a file-local tap gets garbage-collected and
--  silently stops firing. Keeping it on a global keeps hold-to-talk alive.
-- ═══════════════════════════════════════════════════════════════════════

require("hs.ipc")   -- enables the `hs` command-line bridge

wf = wf or {}
wf.HOME    = os.getenv("HOME")
wf.DICTATE = wf.HOME .. "/.config/senti/senti-dictate.sh"
wf.PROMPTS = wf.HOME .. "/.config/senti/senti-prompt.sh"
wf.TARGETSH = wf.HOME .. "/.config/senti/senti-target.sh"
wf.SESSION  = wf.HOME .. "/.config/senti/senti-session.sh"
wf.MENUICON = wf.HOME .. "/.config/senti/menubar/mic.png"
wf.COMMAND = wf.HOME .. "/.config/senti/senti-command.sh"
wf.VISION  = wf.HOME .. "/.config/senti/senti-vision.sh"
wf.SELFILE = wf.HOME .. "/.cache/senti/selection.txt"
wf.SHOT    = wf.HOME .. "/.cache/senti/screen.png"
wf.AUTH    = wf.HOME .. "/.config/senti/senti-mic-auth"  -- AVFoundation mic-permission helper
wf.MODELSH = wf.HOME .. "/.config/senti/senti-model.sh"
wf.LOG     = wf.HOME .. "/Library/Logs/senti.log"
wf.BASH    = "/bin/bash"
wf.micOK   = false   -- cached once macOS authorizes the mic

-- ── Tunables ───────────────────────────────────────────────────────────
wf.TRAILING_SPACE = true   -- add a space after inserted text
wf.HOLD_VERBATIM  = 61     -- keycode: Right Option (⌥)  → hold to dictate
wf.HOLD_PROMPT    = 54     -- keycode: Right Command (⌘) → hold to dictate+optimize
wf.HOLD_COMMAND   = 63     -- keycode: Fn / 🌐 (globe) key → hold to command selected text
local TOGGLE_VERBATIM = {{"ctrl","alt"}, "d"}
local TOGGLE_PROMPT   = {{"ctrl","alt"}, "p"}
local TOGGLE_COMMAND  = {{"ctrl","alt"}, "c"}
local TOGGLE_CONTEXT  = {{"ctrl","alt"}, "v"}   -- screenshot + speak → context-aware insert

-- ── State ──────────────────────────────────────────────────────────────
wf.state = "idle"    -- "idle" | "recording" | "working"
wf.mode  = nil       -- "verbatim" | "prompt"
wf.held  = nil       -- keycode of the hold-key currently down, or nil
wf.targetHint = ""   -- frontmost app at capture time → which model we're prompting for
wf.sessKey    = ""   -- focused WINDOW id → distinguishes your parallel terminals
wf.sessLabel  = ""   -- that window's title → carries project + current task for free

-- ── Logging (so one test press reveals exactly where it breaks) ─────────
function wf.log(msg)
  local f = io.open(wf.LOG, "a")
  if f then f:write(os.date("%H:%M:%S") .. " [hs] " .. msg .. "\n"); f:close() end
end

-- ── UI ─────────────────────────────────────────────────────────────────
-- Menu bar uses a real template image, not an emoji in setTitle: macOS keeps
-- only the alpha channel and tints it for light/dark/active automatically, which
-- is what makes it sit correctly next to system items. State is carried by the
-- floating HUD (which is only ever visible in the non-idle states anyway).
local function menuIcon()
  local img = hs.image.imageFromPath(wf.MENUICON)
  if img then img:setSize({ w = 18, h = 18 }); img:template(true) end
  return img
end

-- ── Floating HUD pill (Wispr-style): bottom-center overlay with waveform ─
local HUD_W, HUD_H, NBARS = 188, 46, 7
wf.hud = { canvas = nil, timer = nil, phase = 0 }

local function hudBuild()
  local scr = hs.screen.mainScreen():frame()
  local x = scr.x + (scr.w - HUD_W) / 2
  local y = scr.y + scr.h - HUD_H - 72
  local c = hs.canvas.new({ x = x, y = y, w = HUD_W, h = HUD_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[#c + 1] = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 22, yRadius = 22 },
                fillColor = { red = 0.09, green = 0.09, blue = 0.11, alpha = 0.94 } }
  c[#c + 1] = { type = "rectangle", action = "stroke", roundedRectRadii = { xRadius = 22, yRadius = 22 },
                strokeColor = { white = 1, alpha = 0.08 }, strokeWidth = 1 }
  c[#c + 1] = { type = "circle", action = "fill", center = { x = 22, y = HUD_H / 2 }, radius = 6,
                fillColor = { red = 1, green = 0.23, blue = 0.19, alpha = 1 } }  -- status dot (idx 3)
  c[#c + 1] = { type = "text", text = "Listening", frame = { x = 36, y = HUD_H / 2 - 10, w = 74, h = 20 },
                textColor = { white = 0.96, alpha = 1 }, textSize = 13,
                textFont = "SF Pro Text" }  -- label (idx 4)
  local bx = 116
  for i = 1, NBARS do  -- waveform bars (idx 5..)
    c[#c + 1] = { type = "rectangle", action = "fill",
                  roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
                  fillColor = { red = 0.55, green = 0.78, blue = 1, alpha = 1 },
                  frame = { x = bx + (i - 1) * 8, y = HUD_H / 2 - 3, w = 4, h = 6 } }
  end
  return c
end

local function hudAnimate()
  local c = wf.hud.canvas
  if not c then return end
  wf.hud.phase = wf.hud.phase + 1
  for i = 1, NBARS do
    local h = 4 + math.floor(12 * math.abs(math.sin(wf.hud.phase * 0.35 + i * 0.9)))
    c[4 + i].frame = { x = 116 + (i - 1) * 8, y = (HUD_H - h) / 2, w = 4, h = h }
  end
end

function wf.hud.show(s)
  if not wf.hud.canvas then wf.hud.canvas = hudBuild() end
  local c = wf.hud.canvas
  if s == "recording" then
    c[3].fillColor = { red = 1, green = 0.23, blue = 0.19, alpha = 1 }   -- red
    local labels = { verbatim = "Listening", prompt = "Prompt", command = "Command", context = "Context" }
    c[4].text = labels[wf.mode] or "Listening"
    if not wf.hud.timer then wf.hud.timer = hs.timer.doEvery(0.06, hudAnimate) end
  elseif s == "working" or s == "thinking" then
    c[3].fillColor = { red = 1, green = 0.72, blue = 0.2, alpha = 1 }    -- amber
    c[4].text = (s == "thinking") and "Thinking…" or "Transcribing…"
    if wf.hud.timer then wf.hud.timer:stop(); wf.hud.timer = nil end
    for i = 1, NBARS do c[4 + i].frame = { x = 116 + (i - 1) * 8, y = HUD_H / 2 - 2, w = 4, h = 4 } end
  end
  c:show()
end

function wf.hud.hide()
  if wf.hud.timer then wf.hud.timer:stop(); wf.hud.timer = nil end
  if wf.hud.canvas then wf.hud.canvas:hide() end
end

function wf.setState(s)
  wf.state = s
  if wf.bar then
    local img = menuIcon()
    if img then wf.bar:setIcon(img); wf.bar:setTitle("")
    else wf.bar:setTitle("●") end   -- template missing (icon build skipped): stay visible
  end
  if s == "recording" or s == "working" then wf.hud.show(s) else wf.hud.hide() end
  -- Watchdog: never let a silent task or a missed key-up wedge the tool.
  if wf.stuckTimer then wf.stuckTimer:stop(); wf.stuckTimer = nil end
  if s == "working" then
    wf.stuckTimer = hs.timer.doAfter(75, function()
      if wf.state == "working" then wf.log("watchdog: 'working' stuck 75s → reset idle"); wf.setState("idle") end
    end)
  elseif s == "recording" then
    wf.stuckTimer = hs.timer.doAfter(150, function()  -- no real dictation runs 2.5 min
      if wf.state == "recording" then
        wf.log("watchdog: 'recording' stuck 150s → cancel + reset")
        hs.task.new(wf.BASH, nil, {wf.DICTATE, "cancel"}):start()
        wf.held = nil; wf.setState("idle")
      end
    end)
  end
end

-- ── Insert text into whatever app is focused (clipboard paste) ──────────
function wf.paste(text)   -- low-level: put text on the clipboard and ⌘V it
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
end

function wf.insert(text)  -- dictation insert: trailing space + clipboard restore
  if not text or text:gsub("%s+","") == "" then wf.log("insert: empty, nothing to paste"); return end
  if wf.TRAILING_SPACE then text = text .. " " end
  local prev = hs.pasteboard.getContents()
  wf.paste(text)
  wf.log("insert: pasted " .. #text .. " chars")
  hs.timer.doAfter(0.5, function()   -- give slow apps time to read the clipboard before restoring
    if prev then hs.pasteboard.setContents(prev) end
  end)
end

-- Command Mode: transform the current selection (or generate at cursor) by voice.
function wf.runCommand(command)
  wf.hud.show("thinking")
  local prevClip = hs.pasteboard.getContents()
  hs.pasteboard.clearContents()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)      -- copy the current selection
  hs.timer.doAfter(0.18, function()
    local sel = hs.pasteboard.getContents() or ""
    local f = io.open(wf.SELFILE, "w"); if f then f:write(sel); f:close() end
    wf.log("command: '" .. command .. "' on " .. #sel .. " selected chars")
    wf.runScript({wf.COMMAND, "", wf.SELFILE}, command, function(_, out)
      wf.setState("idle")
      out = (out or ""):gsub("%s+$", "")
      if out ~= "" then wf.paste(out) end      -- replaces the selection, or inserts at cursor
      wf.log("command: applied " .. #out .. " chars")
      os.remove(wf.SELFILE)                    -- selected text is the user's content; don't leave it on disk
      hs.timer.doAfter(0.5, function() if prevClip then hs.pasteboard.setContents(prevClip) end end)
    end)
  end)
end

-- ── Cache hygiene ──────────────────────────────────────────────────────
-- ~/.cache/senti accumulates the most sensitive artefacts this app touches: the raw
-- audio of what you just said, a full-resolution PNG of your screen, and whatever text
-- you had selected. None of it is needed once the result has been inserted. Sweep it the
-- moment a turn finishes rather than leaving it on disk until the next dictation
-- overwrites it (which, for screen.png, could be days).
wf.CACHE = wf.HOME .. "/.cache/senti"
wf.SWEEPABLE = { "capture.wav", "screen.png", "screen-small.jpg", "selection.txt",
                 "mictest.wav", "selftest-shot.png" }
function wf.sweepCache()
  if wf.state == "recording" then return end   -- capture.wav is in use
  local n = 0
  for _, f in ipairs(wf.SWEEPABLE) do
    if os.remove(wf.CACHE .. "/" .. f) then n = n + 1 end
  end
  if n > 0 then wf.log("cache swept: " .. n .. " file(s)") end
  return n
end

-- Run a Senti script with the user's spoken text in the ENVIRONMENT, never argv.
-- `ps -Ao args` is readable by every process on the machine, so anything on a command
-- line is effectively public — and the speech is the one thing this app protects.
-- setEnvironment replaces the environment wholesale, so re-supply what the scripts need.
function wf.runScript(args, spoken, cb)
  local t = hs.task.new(wf.BASH, cb, args)
  if not t then wf.log("runScript: could not create task"); return nil end
  t:setEnvironment({
    HOME = wf.HOME,
    PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    SENTI_IN = spoken or "",
    SENTI_SKEY = wf.sessKey or "",
    SENTI_SLABEL = wf.sessLabel or "",
  })
  t:start()
  return t
end

-- ── Transcription pipeline ─────────────────────────────────────────────
-- Poll briefly for the async screenshot — a very short utterance can outrun the
-- ~200ms screencapture. cb(true) if it appears within ~1s, else cb(false).
function wf.awaitShot(tries, cb)
  local f = io.open(wf.SHOT, "r")
  if f then f:close(); cb(true); return end
  if tries <= 0 then cb(false); return end
  hs.timer.doAfter(0.25, function() wf.awaitShot(tries - 1, cb) end)
end

-- Run the vision engine; surface failures instead of silently inserting nothing.
function wf.runVision(raw, kind)
  wf.hud.show("thinking")
  -- 4th arg is the target-model hint: prompt mode runs through THIS path whenever Screen
  -- Recording is granted, so it needs the same guidance the text-only path gets.
  wf.runScript({wf.VISION, "", wf.SHOT, kind, wf.targetHint}, raw, function(exitCode, out)
    wf.setState("idle")
    if exitCode ~= 0 then
      wf.log("vision failed (exit " .. tostring(exitCode) .. ")")
      hs.alert.show("⚠️ Senti: request failed — check your network or OpenAI key")
    else
      wf.insert((out or ""):gsub("%s+$", ""))
    end
    wf.sweepCache()   -- the screenshot is a picture of your screen; don't let it linger
  end)
end

function wf.handleTranscript(raw)
  raw = (raw or ""):gsub("^%s+",""):gsub("%s+$","")
  -- Record the turn against this window's session before acting on it, so the next
  -- dictation in the SAME window can resolve back-references. Fire-and-forget.
  if raw ~= "" and raw ~= "__WF_SERVER_DOWN__" and wf.sessKey ~= "" then
    wf.runScript({wf.SESSION, "note", wf.sessKey, wf.sessLabel, tostring(wf.mode or "dictate")},
                 raw, nil)
  end
  if raw == "__WF_SERVER_DOWN__" then
    wf.setState("idle")
    hs.alert.show("⚠️ Whisper engine is not running.\nMenubar 🎤 → Restart engine")
    return
  end
  if raw == "" then wf.log("transcript: empty (silence/gated)"); wf.setState("idle"); return end

  if wf.mode == "context" then
    wf.awaitShot(4, function(has)
      if has then wf.runVision(raw, "context")
      else
        wf.setState("idle")
        wf.log("context: no screenshot — Screen Recording not granted")
        hs.alert.show("📸 Context mode needs Screen Recording.\nSystem Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it")
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end
    end)
  elseif wf.mode == "command" then
    wf.runCommand(raw)                 -- raw = the spoken instruction
  elseif wf.mode == "prompt" then
    wf.awaitShot(4, function(has)
      if has then wf.runVision(raw, "prompt")   -- screen context → context-aware prompt
      else                                       -- no screen → text-only prompt path
        wf.hud.show("thinking")
        wf.runScript({wf.PROMPTS, "", wf.targetHint}, raw, function(_, stdout)
          wf.setState("idle"); wf.insert(stdout)
        end)
      end
    end)
  else
    wf.setState("idle"); wf.insert(raw); wf.sweepCache()
  end
end

function wf.record()
  wf.setState("recording")
  wf.log("record: mode="..tostring(wf.mode))
  hs.task.new(wf.BASH, nil, {wf.DICTATE, "start"}):start()
end

-- Prompt for / open the mic permission. `andThenRecord` = record once granted.
function wf.grantMic(andThenRecord)
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    if out == "AUTHORIZED" then
      wf.micOK = true; wf.log("mic AUTHORIZED")
      if andThenRecord then wf.record() end
    elseif out == "DENIED" or out == "RESTRICTED" then
      wf.log("mic "..out)
      hs.alert.show("🎤 Microphone is blocked for Hammerspoon.\nSystem Settings ▸ Privacy & Security ▸\nMicrophone → turn ON Hammerspoon")
      hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'")
    else
      hs.alert.show("🎤 requesting mic access…")
    end
  end, {"--request"}):start()
end

function wf.beginCapture(m)
  if wf.state ~= "idle" then wf.log("beginCapture ignored: state="..wf.state); return end
  wf.mode = m
  -- Which app is the user in? That tells prompt mode which model this prompt is
  -- headed for, so it can tailor to that model. Read it at capture time, before
  -- any focus change, and it costs nothing — no extra API call, no latency.
  local ok, app = pcall(function() return hs.application.frontmostApplication() end)
  wf.targetHint = (ok and app and app:name()) or ""
  -- Session identity: the focused WINDOW, not the app. Three Claude Code terminals are
  -- all "Terminal" but are three different pieces of work. The window title already
  -- contains the project and what that session is doing, so we get working context with
  -- no screenshot, no API call, and nothing leaving the Mac.
  local ok2, win = pcall(function() return hs.window.focusedWindow() end)
  if ok2 and win then
    wf.sessKey   = tostring(win:id() or "")
    wf.sessLabel = tostring(win:title() or "")
  else
    wf.sessKey, wf.sessLabel = "", ""
  end
  if wf.micOK then wf.record(); return end
  -- First use: check permission without prompting; act on the result.
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    wf.log("mic probe: "..out)
    if out == "AUTHORIZED" then
      wf.micOK = true; wf.record()
    elseif out == "NOTDETERMINED" then
      hs.alert.show("🎤 Allow the microphone prompt,\nthen hold ⌥ again to dictate")
      wf.grantMic(false)   -- triggers the macOS prompt
    else  -- DENIED / RESTRICTED
      wf.grantMic(false)   -- shows the Settings guidance + opens the pane
    end
  end, {"--probe"}):start()
end

function wf.endCapture()
  if wf.state ~= "recording" then wf.log("endCapture ignored: state="..wf.state); return end
  wf.setState("working")
  wf.log("endCapture: transcribing")
  hs.task.new(wf.BASH, function(_, stdout) wf.handleTranscript(stdout) end,
              {wf.DICTATE, "stop"}):start()
end

-- Snapshot the screen now (for prompt + context modes), then start capturing.
function wf.snapAndCapture(mode)
  if wf.state ~= "idle" then return end
  os.remove(wf.SHOT)   -- clear any stale shot so a failed capture can't reuse an old screen
  hs.task.new("/usr/sbin/screencapture", nil, {"-x", "-m", wf.SHOT}):start()
  wf.beginCapture(mode)
end

-- ── Menu bar ───────────────────────────────────────────────────────────
wf.bar = hs.menubar.new()
local function menu()
  local serverUp = hs.execute(wf.BASH .. " '" .. wf.DICTATE .. "' server"):gsub("%s+","") == "up"
  local tapOn = wf.flagWatcher and wf.flagWatcher:isEnabled()
  local curModel = hs.execute(wf.BASH .. " '" .. wf.MODELSH .. "' current"):gsub("%s+","")
  return {
    { title = "Senti — local dictation", disabled = true },
    { title = serverUp and "● engine: running" or "○ engine: STOPPED", disabled = true },
    { title = tapOn and "● hold-to-talk: armed" or "○ hold-to-talk: OFF", disabled = true },
    { title = "-" },
    { title = "Hold right ⌥ = dictate · right ⌘ = prompt · Fn(🌐) = command", disabled = true },
    { title = "Toggles: ⌃⌥D dictate · ⌃⌥P prompt · ⌃⌥C command · ⌃⌥V context", disabled = true },
    { title = "-" },
    { title = "Speed", menu = {
        { title = (curModel == "fast" and "✓ " or "   ") .. "Fast (base.en, ~0.3s)", fn = function()
            hs.alert.show("Switching to Fast model…")
            hs.task.new(wf.BASH, function() hs.alert.show("⚡ Fast mode on") end, {wf.MODELSH, "fast"}):start()
          end },
        { title = (curModel ~= "fast" and "✓ " or "   ") .. "Accurate (turbo, ~0.8s)", fn = function()
            hs.alert.show("Switching to Accurate model…")
            hs.task.new(wf.BASH, function() hs.alert.show("🎯 Accurate mode on") end, {wf.MODELSH, "accurate"}):start()
          end },
      } },
    { title = "-" },
    { title = "🎙️  Grant / test microphone", fn = function()
        -- Step 1: request authorization (prompts on first use), then Step 2: verify capture.
        hs.task.new(wf.AUTH, function(_, aout)
          aout = (aout or ""):gsub("%s+","")
          if aout ~= "AUTHORIZED" then
            wf.grantMic(false); return
          end
          wf.micOK = true
          hs.alert.show("Recording 1.2s… say something")
          hs.task.new(wf.BASH, function(_, out)
            local amp = tonumber((out or ""):match("[%d%.]+")) or 0
            if (out or ""):find("NO_MIC") or amp < 0.005 then
              hs.alert.show(string.format("⚠️ Very low signal (peak %.4f).\nCheck your input device / mic isn't muted.", amp))
            else
              hs.alert.show(string.format("✅ Microphone works (peak %.2f). You're set!", amp))
            end
          end, {wf.DICTATE, "mictest"}):start()
        end, {"--request"}):start()
      end },
    { title = "📸  Grant screen recording (for ⌃⌥V context)", fn = function()
        hs.execute("/usr/sbin/screencapture -x -m '" .. wf.SHOT .. "' 2>/dev/null")  -- nudges the prompt
        hs.alert.show("System Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it")
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end },
    { title = "Re-arm hotkeys", fn = function() wf.armTap(); hs.alert.show("Hotkeys re-armed") end },
    { title = "-" },
    { title = "Restart engine", fn = function()
        hs.execute("/bin/launchctl kickstart -k gui/$(id -u)/com.leo.senti")
        hs.alert.show("Whisper engine restarting…")
      end },
    { title = "Open log", fn = function() hs.execute("/usr/bin/open '" .. wf.LOG .. "'") end },
    { title = "-" },
    { title = "Quit Senti", fn = function() hs.application.get("Hammerspoon"):kill() end },
  }
end
if wf.bar then wf.bar:setMenu(menu) end

-- ── Hold-to-talk event tap (kept on wf.* so GC can't kill it) ───────────
function wf.armTap()
  if wf.flagWatcher then wf.flagWatcher:stop() end
  wf.flagWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
    local ok, err = pcall(function()
      local code, flags = e:getKeyCode(), e:getFlags()
      if code == wf.HOLD_VERBATIM then
        local down = flags.alt == true
        if down and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: right⌥ down"); wf.beginCapture("verbatim")
        elseif not down and wf.held == wf.HOLD_VERBATIM then
          wf.held = nil; wf.log("tap: right⌥ up"); wf.endCapture()
        end
      elseif code == wf.HOLD_PROMPT then
        local down = flags.cmd == true
        if down and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: right⌘ down"); wf.snapAndCapture("prompt")
        elseif not down and wf.held == wf.HOLD_PROMPT then
          wf.held = nil; wf.log("tap: right⌘ up"); wf.endCapture()
        end
      elseif code == wf.HOLD_COMMAND then
        local down = flags.fn == true
        if down and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: Fn down"); wf.beginCapture("command")
        elseif not down and wf.held == wf.HOLD_COMMAND then
          wf.held = nil; wf.log("tap: Fn up"); wf.endCapture()
        end
      end
    end)
    if not ok then wf.log("tap ERROR: " .. tostring(err)) end
    return false   -- never swallow the key
  end)
  wf.flagWatcher:start()
  wf.log("armTap: eventtap started, enabled=" .. tostring(wf.flagWatcher:isEnabled()))
end
wf.armTap()

-- Watchdog: macOS disables an event tap if a callback ever stalls; re-arm it.
if wf.watchdog then wf.watchdog:stop() end
wf.watchdog = hs.timer.doEvery(5, function()
  if wf.flagWatcher and not wf.flagWatcher:isEnabled() then
    wf.log("watchdog: tap was disabled — re-arming")
    wf.flagWatcher:start()
  end
end)

-- ── Hands-free toggles (Carbon hotkeys; retained by Hammerspoon) ────────
if wf.hkV then wf.hkV:delete() end
if wf.hkP then wf.hkP:delete() end
wf.hkV = hs.hotkey.bind(TOGGLE_VERBATIM[1], TOGGLE_VERBATIM[2], function()
  wf.log("toggle ⌃⌥D")
  if wf.state == "recording" then wf.endCapture() else wf.beginCapture("verbatim") end
end)
wf.hkP = hs.hotkey.bind(TOGGLE_PROMPT[1], TOGGLE_PROMPT[2], function()
  wf.log("toggle ⌃⌥P")
  if wf.state == "recording" then wf.endCapture() else wf.snapAndCapture("prompt") end
end)
if wf.hkC then wf.hkC:delete() end
wf.hkC = hs.hotkey.bind(TOGGLE_COMMAND[1], TOGGLE_COMMAND[2], function()
  wf.log("toggle ⌃⌥C")
  if wf.state == "recording" then wf.endCapture() else wf.beginCapture("command") end
end)
if wf.hkVi then wf.hkVi:delete() end
wf.hkVi = hs.hotkey.bind(TOGGLE_CONTEXT[1], TOGGLE_CONTEXT[2], function()
  wf.log("toggle ⌃⌥V (context)")
  if wf.state == "recording" then wf.endCapture() else wf.snapAndCapture("context") end
end)

-- ── Diagnostics helper (callable via `hs -c 'return wf.diag()'`) ─────────
function wf.diag()
  return string.format(
    "state=%s | tap=%s | accessibility=%s | hotkeys=%d | server=%s",
    wf.state,
    wf.flagWatcher and tostring(wf.flagWatcher:isEnabled()) or "nil",
    tostring(hs.accessibilityState()),
    #hs.hotkey.getHotkeys(),
    hs.execute(wf.BASH.." '"..wf.DICTATE.."' server"):gsub("%s+",""))
end

-- ── Launch/appearance ──────────────────────────────────────────────────
hs.autoLaunch(true)
hs.dockIcon(false)
wf.setState("idle")
wf.sweepCache()   -- clear anything a previous session left behind (e.g. after a crash)
-- Backstop: a turn that errors out mid-flight never reaches its completion callback,
-- so sweep periodically too. Cheap (a handful of os.remove calls) and it means audio
-- and screenshots can't outlive the turn that created them by more than a minute.
if wf.sweeper then wf.sweeper:stop() end
wf.sweeper = hs.timer.doEvery(60, function()
  if wf.state == "idle" then wf.sweepCache() end
end)
-- Session files are transcripts of your speech. Expire them on the same principle as
-- the cache: keep them long enough to be useful within a work session, not forever.
if wf.sessSweeper then wf.sessSweeper:stop() end
wf.sessSweeper = hs.timer.doEvery(1800, function()
  wf.runScript({wf.SESSION, "sweep"}, "", nil)
end)
wf.runScript({wf.SESSION, "sweep"}, "", nil)   -- and once at launch
wf.log("=== init.lua loaded ===")

-- Startup mic-permission probe (no prompt); nudge once if not yet authorized.
hs.task.new(wf.AUTH, function(_, out)
  out = (out or ""):gsub("%s+","")
  wf.log("startup mic probe: "..out)
  if out == "AUTHORIZED" then
    wf.micOK = true
    hs.alert.show("🎤 Senti ready — hold right ⌥ to dictate")
  else
    hs.alert.show("🎤 Senti: one step left —\nmenu bar 🎤 → Grant / test microphone")
  end
end, {"--probe"}):start()
