-- ═══════════════════════════════════════════════════════════════════════
--  Sanele — free, 100% local speech-to-text (a Wispr Flow clone)
--  Audio is recorded locally, transcribed by a local whisper.cpp server on
--  127.0.0.1, and never leaves this Mac.
--
--  Everything lives on the global `wf` table on purpose: Hammerspoon does NOT
--  retain hs.eventtap objects, so a file-local tap gets garbage-collected and
--  silently stops firing. Keeping it on a global keeps hold-to-talk alive.
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY: `require("hs.ipc")` opens a local message port that the `hs` CLI uses to
-- run ARBITRARY Lua inside Hammerspoon. Because Hammerspoon holds Accessibility,
-- Microphone and Screen Recording, any same-uid process could `hs -c '<lua>'` to
-- borrow those TCC grants prompt-free (keylog, screen/mic capture, read the API key).
-- It is therefore OFF by default. Diagnostics run through the log instead
-- (menu bar → "Write diagnostics to log", and a line at startup) — no open port needed.
-- Opt back in for live `hs -c` debugging with:  touch ~/.cache/sanele/allow-ipc
if io.open(os.getenv("HOME") .. "/.cache/sanele/allow-ipc") then
  require("hs.ipc")   -- developer opt-in: restores the `hs` command-line bridge
end

wf = wf or {}
wf.HOME    = os.getenv("HOME")
wf.DICTATE = wf.HOME .. "/.config/sanele/sanele-dictate.sh"
wf.PROMPTS = wf.HOME .. "/.config/sanele/sanele-prompt.sh"
wf.SESSION  = wf.HOME .. "/.config/sanele/sanele-session.sh"
wf.MENUICON = wf.HOME .. "/.config/sanele/menubar/mic.png"
wf.COMMAND = wf.HOME .. "/.config/sanele/sanele-command.sh"
wf.VISION  = wf.HOME .. "/.config/sanele/sanele-vision.sh"
wf.CTXPRE  = wf.HOME .. "/.config/sanele/sanele-lib.sh"   -- run directly = prefetch context
wf.SELFILE = wf.HOME .. "/.cache/sanele/selection.txt"
wf.SHOT    = wf.HOME .. "/.cache/sanele/screen.png"
wf.AUTH    = wf.HOME .. "/.config/sanele/sanele-mic-auth"  -- AVFoundation mic-permission helper
wf.MODELSH = wf.HOME .. "/.config/sanele/sanele-model.sh"
wf.LOG     = wf.HOME .. "/Library/Logs/sanele.log"
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

-- ── Floating HUD pill: bottom-center overlay, Sanele mark + live waveform ─
-- Brand-aligned: the violet is the app icon's gradient top (#A78BFA on dark),
-- so the HUD reads as part of the product rather than a generic system alert.
-- The mark on the left is the SAME geometry as assets/icon-menubar.svg, drawn
-- natively in canvas rather than loaded as an image — a template PNG can only
-- be black, and this needs to change colour to carry state.
local HUD_W, HUD_H, NBARS = 224, 54, 8
local BAR_W, BAR_GAP, BAR_X = 4, 8, 142
local ACCENT  = { red = 0.655, green = 0.545, blue = 0.980, alpha = 1 }  -- violet, recording
local WORKING = { red = 0.984, green = 0.749, blue = 0.141, alpha = 1 }  -- amber, transcribing
wf.hud = { canvas = nil, timer = nil, phase = 0, tone = ACCENT }

-- Element indices. Named because a bare c[4] is unreadable and the waveform
-- loop appends after them — inserting an element silently shifts every access.
local I_CAP, I_STEM, I_BASE, I_ARC, I_LABEL = 3, 4, 5, 6, 7

-- Sanele mark, scaled from the 44px source viewBox onto the pill.
local S, OX, OY = 0.62, 12.36, 12.36   -- scale + offset: centres the glyph at (26, 26)
local function gx(v) return v * S + OX end
local function gy(v) return v * S + OY end

local function hudBuild()
  local scr = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({ x = scr.x + (scr.w - HUD_W) / 2,
                            y = scr.y + scr.h - HUD_H - 72, w = HUD_W, h = HUD_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  c[1] = { type = "rectangle", action = "fill",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           fillColor = { red = 0.055, green = 0.055, blue = 0.071, alpha = 0.96 },
           withShadow = true,
           shadow = { blurRadius = 18, offset = { h = -4, w = 0 },
                      color = { alpha = 0.45, white = 0 } } }
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           strokeColor = { white = 1, alpha = 0.10 }, strokeWidth = 1 }

  -- The mark: capsule + stem + base + cradle arc (same shapes as the app icon).
  c[I_CAP]  = { type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = gx(5.5) - gx(0), yRadius = gx(5.5) - gx(0) },
                fillColor = ACCENT,
                frame = { x = gx(16.5), y = gy(7), w = 11 * S, h = 19 * S } }
  c[I_STEM] = { type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = 1.3 * S, yRadius = 1.3 * S }, fillColor = ACCENT,
                frame = { x = gx(20.7), y = gy(32), w = 2.6 * S, h = 5 * S } }
  c[I_BASE] = { type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = 1.3 * S, yRadius = 1.3 * S }, fillColor = ACCENT,
                frame = { x = gx(15.5), y = gy(35.6), w = 13 * S, h = 2.6 * S } }
  -- 90°→270° sweeps clockwise through the bottom, giving the U-shaped cradle.
  c[I_ARC]  = { type = "arc", action = "stroke", arcRadii = false,
                center = { x = gx(22), y = gy(22.5) }, radius = 10.5 * S,
                startAngle = 90, endAngle = 270,
                strokeColor = ACCENT, strokeWidth = 2.6 * S, strokeCapStyle = "round" }

  c[I_LABEL] = { type = "text", text = "Listening",
                 frame = { x = 46, y = HUD_H / 2 - 10, w = 92, h = 20 },
                 textColor = { white = 0.97, alpha = 1 }, textSize = 13,
                 textFont = "SF Pro Text" }

  for i = 1, NBARS do
    c[I_LABEL + i] = { type = "rectangle", action = "fill",
                       roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
                       fillColor = ACCENT,
                       frame = { x = BAR_X + (i - 1) * BAR_GAP, y = HUD_H / 2 - 2,
                                 w = BAR_W, h = 4 } }
  end
  return c
end

-- Two animations off one timer. Recording: a waveform with a centre-weighted
-- envelope, so the middle bars run taller than the edges the way real speech
-- energy does — a flat sine across all bars reads as a loading spinner, not a voice.
-- Working: a single travelling pulse, which says "busy" without implying it is
-- still hearing you.
local function hudAnimate()
  local c = wf.hud.canvas
  if not c then return end
  wf.hud.phase = wf.hud.phase + 1
  local working = (wf.hud.tone == WORKING)
  for i = 1, NBARS do
    local h
    if working then
      -- A travelling sine, not a discrete pulse. A pulse indexed by
      -- (phase % (NBARS+3)) spends ~27% of its cycle past the last bar with
      -- nothing lit, which reads as frozen — the exact impression this state
      -- must never give. A wave always has motion somewhere on the strip.
      h = 4 + 9 * (0.5 + 0.5 * math.sin(wf.hud.phase * 0.22 - i * 0.7))
    else
      -- Centre-weighted so the middle bars run taller, the way speech energy
      -- does. Floor the envelope at 0.65: at 0.5 the outer bars collapse to
      -- 4px circles and the waveform reads as a trailing ellipsis.
      local env = 0.65 + 0.35 * math.sin(math.pi * (i - 0.5) / NBARS)
      h = 4 + 15 * env * (0.5 + 0.5 * math.sin(wf.hud.phase * 0.30 + i * 0.75))
    end
    c[I_LABEL + i].frame = { x = BAR_X + (i - 1) * BAR_GAP, y = (HUD_H - h) / 2,
                             w = BAR_W, h = h }
  end
end

local function hudTint(col)
  local c = wf.hud.canvas
  wf.hud.tone = col
  c[I_CAP].fillColor, c[I_STEM].fillColor, c[I_BASE].fillColor = col, col, col
  c[I_ARC].strokeColor = col
  for i = 1, NBARS do c[I_LABEL + i].fillColor = col end
end

function wf.hud.show(s)
  if not wf.hud.canvas then wf.hud.canvas = hudBuild() end
  local c = wf.hud.canvas
  if s == "recording" then
    hudTint(ACCENT)
    local labels = { verbatim = "Listening", prompt = "Prompt",
                     command = "Command", context = "Context" }
    c[I_LABEL].text = labels[wf.mode] or "Listening"
  elseif s == "working" or s == "thinking" then
    hudTint(WORKING)
    c[I_LABEL].text = (s == "thinking") and "Thinking…" or "Transcribing…"
  end
  -- One timer for both states; hudAnimate branches on tone. Previously the
  -- working state stopped the timer and froze the bars flat, which looked hung.
  if not wf.hud.timer then wf.hud.timer = hs.timer.doEvery(0.05, hudAnimate) end
  c:show()
end

function wf.hud.hide()
  if wf.hud.timer then wf.hud.timer:stop(); wf.hud.timer = nil end
  if wf.hud.canvas then wf.hud.canvas:hide() end
end

-- ── Toast: messages in the HUD's visual language, carrying the Sanele mark ──
-- hs.alert's style table is text-only — no image key — so the brand was being
-- stood in for by a 🎤 emoji. This draws the real mark, same geometry as the
-- HUD and the app icon, and tints it to carry severity.
wf.toast = { canvas = nil, timer = nil }
local T_INFO = ACCENT
local T_WARN = { red = 0.98, green = 0.55, blue = 0.24, alpha = 1 }
local T_OK   = { red = 0.36, green = 0.85, blue = 0.55, alpha = 1 }

-- The mark as a list of canvas elements, positioned around (cx, cy). Factored
-- out because the HUD and the toast must never drift apart visually.
local function markElements(cx, cy, k, col)
  local function mx(v) return (v - 22) * k + cx end
  local function my(v) return (v - 22) * k + cy end
  return {
    { type = "rectangle", action = "fill", fillColor = col,
      roundedRectRadii = { xRadius = 5.5 * k, yRadius = 5.5 * k },
      frame = { x = mx(16.5), y = my(7), w = 11 * k, h = 19 * k } },
    { type = "rectangle", action = "fill", fillColor = col,
      roundedRectRadii = { xRadius = 1.3 * k, yRadius = 1.3 * k },
      frame = { x = mx(20.7), y = my(32), w = 2.6 * k, h = 5 * k } },
    { type = "rectangle", action = "fill", fillColor = col,
      roundedRectRadii = { xRadius = 1.3 * k, yRadius = 1.3 * k },
      frame = { x = mx(15.5), y = my(35.6), w = 13 * k, h = 2.6 * k } },
    { type = "arc", action = "stroke", arcRadii = false, strokeColor = col,
      center = { x = mx(22), y = my(22.5) }, radius = 10.5 * k,
      startAngle = 90, endAngle = 270,
      strokeWidth = 2.6 * k, strokeCapStyle = "round" },
  }
end

function wf.notify(msg, secs, tone)
  secs, tone = secs or 3, tone or T_INFO
  local lines = 1
  for _ in tostring(msg):gmatch("\n") do lines = lines + 1 end
  local W, H = 400, 34 + 19 * lines
  local scr = hs.screen.mainScreen():frame()
  if wf.toast.canvas then wf.toast.canvas:delete(); wf.toast.canvas = nil end
  local c = hs.canvas.new({ x = scr.x + (scr.w - W) / 2,
                            y = scr.y + scr.h - H - 138, w = W, h = H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "fill",
           roundedRectRadii = { xRadius = 16, yRadius = 16 },
           fillColor = { red = 0.055, green = 0.055, blue = 0.071, alpha = 0.96 },
           withShadow = true,
           shadow = { blurRadius = 18, offset = { h = -4, w = 0 },
                      color = { alpha = 0.45, white = 0 } } }
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = 16, yRadius = 16 },
           strokeColor = { white = 1, alpha = 0.10 }, strokeWidth = 1 }
  for _, e in ipairs(markElements(32, H / 2, 0.52, tone)) do c[#c + 1] = e end
  c[#c + 1] = { type = "text", text = tostring(msg),
                frame = { x = 58, y = 15, w = W - 74, h = H - 24 },
                textColor = { white = 0.97, alpha = 1 }, textSize = 13,
                textFont = "SF Pro Text" }
  c:show()
  wf.toast.canvas = c
  if wf.toast.timer then wf.toast.timer:stop() end
  wf.toast.timer = hs.timer.doAfter(secs, function()
    if wf.toast.canvas then wf.toast.canvas:delete(); wf.toast.canvas = nil end
  end)
end
wf.TONE = { info = T_INFO, warn = T_WARN, ok = T_OK }

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
    wf.log("command: " .. #command .. " chars on " .. #sel .. " selected chars")  -- not the text itself
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
-- ~/.cache/sanele accumulates the most sensitive artefacts this app touches: the raw
-- audio of what you just said, a full-resolution PNG of your screen, and whatever text
-- you had selected. None of it is needed once the result has been inserted. Sweep it the
-- moment a turn finishes rather than leaving it on disk until the next dictation
-- overwrites it (which, for screen.png, could be days).
wf.CACHE = wf.HOME .. "/.cache/sanele"
-- Sweep by PATTERN, not a hardcoded filename list: a stale full-res screenshot from
-- July survived on disk for weeks precisely because it wasn't on the old list. Any
-- top-level audio / screenshot / selection artefact is sensitive and gets removed;
-- subdirectories (sessions/, brain/), prefs (*.pref) and the allow-ipc toggle are left
-- alone. These files are same-uid readable regardless of mode, so the real protection
-- is a short on-disk life — this runs at the end of every turn, at startup, and on a
-- 60s backstop.
-- "ctx-*" are the prefetched prompt-context files (vault digest + session transcript,
-- written at key-down by sanele-lib.sh). They're turn artefacts like the rest — the
-- self-test asserts this pattern still covers them.
function wf.sweepSensitive(name)
  return name:match("%.wav$") or name:match("%.png$") or name:match("%.jpg$")
      or name:match("%.jpeg$") or name == "selection.txt" or name:match("^ctx%-")
end
function wf.sweepCache()
  if wf.state == "recording" then return end   -- capture.wav is in use
  local n = 0
  local ok, iter, dObj = pcall(hs.fs.dir, wf.CACHE)
  if ok and iter then
    for entry in iter, dObj do
      if entry ~= "." and entry ~= ".." and wf.sweepSensitive(entry) then
        if os.remove(wf.CACHE .. "/" .. entry) then n = n + 1 end
      end
    end
  end
  if n > 0 then wf.log("cache swept: " .. n .. " file(s)") end
  return n
end

-- Run a Sanele script with the user's spoken text in the ENVIRONMENT, never argv.
-- `ps -Ao args` is readable by every process on the machine, so anything on a command
-- line is effectively public — and the speech is the one thing this app protects.
-- setEnvironment replaces the environment wholesale, so re-supply what the scripts need.
function wf.runScript(args, spoken, cb)
  local t = hs.task.new(wf.BASH, cb, args)
  if not t then wf.log("runScript: could not create task"); return nil end
  t:setEnvironment({
    HOME = wf.HOME,
    PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    SANELE_IN = spoken or "",
    SANELE_SKEY = wf.sessKey or "",
    SANELE_SLABEL = wf.sessLabel or "",
    SANELE_HINT = wf.targetHint or "",
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
  -- Target hint + session identity ride the env via runScript; argv carries only paths/kind.
  wf.runScript({wf.VISION, "", wf.SHOT, kind}, raw, function(exitCode, out)
    wf.setState("idle")
    if exitCode ~= 0 then
      wf.log("vision failed (exit " .. tostring(exitCode) .. ")")
      wf.notify("Request failed — check your network or OpenAI key", 4, wf.TONE.warn)
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
    -- key/label ride the env (runScript sets SANELE_SKEY/SANELE_SLABEL); argv carries
    -- only the subcommand and mode — window titles stay out of `ps`.
    wf.runScript({wf.SESSION, "note", "", "", tostring(wf.mode or "dictate")}, raw, nil)
  end
  if raw == "__WF_MIC_DEAD__" then
    -- Peak was exactly 0.000000: the mic returned pure silence, which on macOS almost
    -- always means Hammerspoon's Microphone permission is missing/revoked or the input
    -- device is muted — NOT that the user said nothing. Real turns in the log lost 50s
    -- and 78s of speech to this with zero feedback. Name the cause and open the fix.
    wf.setState("idle")
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Your microphone captured no audio.\nCheck it isn't muted, or re-grant Microphone:\nmenu bar → Grant / test microphone", 5, wf.TONE.warn)
    wf.micOK = false   -- force a fresh permission probe on the next capture
    return
  end
  if raw == "__WF_SERVER_DOWN__" then
    wf.setState("idle")
    wf.notify("Whisper engine is not running.\nMenu bar → Restart engine", 4, wf.TONE.warn)
    return
  end
  if raw == "" then
    -- NEVER fail silently here. The log shows real turns where the user held the key
    -- for 50s and 78s, waited ~30s for transcription, and got NOTHING back — no sound,
    -- no alert, no text — because this branch just returned. Silent, undiagnosed
    -- failure is the single most-cited complaint about competing dictation tools;
    -- losing a minute of speech with no signal is the worst thing this app can do.
    -- Say what happened, and (below) keep the audio so it's recoverable.
    wf.log("transcript: empty (silence/gated) — alerting user")
    wf.setState("idle")
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Nothing was transcribed.\nThe mic may be muted or the audio was silent.\nMenu bar → Grant / test microphone", 4, wf.TONE.warn)
    return
  end

  if wf.mode == "context" then
    wf.awaitShot(4, function(has)
      if has then wf.runVision(raw, "context")
      else
        wf.setState("idle")
        wf.log("context: no screenshot — Screen Recording not granted")
        wf.notify("Context mode needs Screen Recording.\nSystem Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it", 5, wf.TONE.warn)
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
        wf.runScript({wf.PROMPTS}, raw, function(_, stdout)
          wf.setState("idle"); wf.insert(stdout); wf.sweepCache()
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
      wf.notify("Microphone is blocked for Hammerspoon.\nSystem Settings ▸ Privacy & Security ▸\nMicrophone → turn ON Hammerspoon", 5, wf.TONE.warn)
      hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'")
    else
      wf.notify("Requesting microphone access…")
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
  -- Prompt mode assembles ~220ms of context (target KB + vault digest + session memory).
  -- Start it NOW, while the user is still speaking, so the live call reads a warm file
  -- instead of paying for three bash spawns at the exact moment they're waiting.
  -- Fire-and-forget: if it doesn't finish in time, the shared functions just build
  -- inline as before. Everything it needs (sessKey/sessLabel/targetHint) is set above.
  if m == "prompt" then wf.runScript({wf.CTXPRE}, "", nil) end
  if wf.micOK then wf.record(); return end
  -- First use: check permission without prompting; act on the result.
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    wf.log("mic probe: "..out)
    if out == "AUTHORIZED" then
      wf.micOK = true; wf.record()
    elseif out == "NOTDETERMINED" then
      wf.notify("Allow the microphone prompt,\nthen hold ⌥ again to dictate", 4)
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
  -- MUST go through runScript: sanele-dictate.sh reads SANELE_SLABEL to build the
  -- whisper vocabulary hint (project name → correct identifier transcription). A bare
  -- hs.task.new carries no Sanele env, so the hint silently loses its best term.
  wf.runScript({wf.DICTATE, "stop"}, "", function(_, stdout) wf.handleTranscript(stdout) end)
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
    { title = "Sanele — local dictation", disabled = true },
    { title = serverUp and "● engine: running" or "○ engine: STOPPED", disabled = true },
    { title = tapOn and "● hold-to-talk: armed" or "○ hold-to-talk: OFF", disabled = true },
    { title = "-" },
    { title = "Hold right ⌥ = dictate · right ⌘ = prompt · Fn(🌐) = command", disabled = true },
    { title = "Toggles: ⌃⌥D dictate · ⌃⌥P prompt · ⌃⌥C command · ⌃⌥V context", disabled = true },
    { title = "-" },
    { title = "Speed", menu = {
        { title = (curModel == "fast" and "✓ " or "   ") .. "Fast (base.en, ~0.3s)", fn = function()
            wf.notify("Switching to Fast model…")
            hs.task.new(wf.BASH, function() wf.notify("Fast mode on", 2) end, {wf.MODELSH, "fast"}):start()
          end },
        { title = (curModel ~= "fast" and "✓ " or "   ") .. "Accurate (turbo, ~0.8s)", fn = function()
            wf.notify("Switching to Accurate model…")
            hs.task.new(wf.BASH, function() wf.notify("Accurate mode on", 2) end, {wf.MODELSH, "accurate"}):start()
          end },
      } },
    { title = "-" },
    { title = "Grant / test microphone", fn = function()
        -- Step 1: request authorization (prompts on first use), then Step 2: verify capture.
        hs.task.new(wf.AUTH, function(_, aout)
          aout = (aout or ""):gsub("%s+","")
          if aout ~= "AUTHORIZED" then
            wf.grantMic(false); return
          end
          wf.micOK = true
          wf.notify("Recording 1.2s… say something", 2)
          hs.task.new(wf.BASH, function(_, out)
            local amp = tonumber((out or ""):match("[%d%.]+")) or 0
            if (out or ""):find("NO_MIC") or amp < 0.005 then
              wf.notify(string.format("Very low signal (peak %.4f).\nCheck your input device / mic isn't muted.", amp), 5, wf.TONE.warn)
            else
              wf.notify(string.format("Microphone works (peak %.2f). You're set!", amp), 3, wf.TONE.ok)
            end
          end, {wf.DICTATE, "mictest"}):start()
        end, {"--request"}):start()
      end },
    { title = "Grant screen recording (for ⌃⌥V context)", fn = function()
        hs.execute("/usr/sbin/screencapture -x -m '" .. wf.SHOT .. "' 2>/dev/null")  -- nudges the prompt
        wf.notify("System Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it", 5, wf.TONE.warn)
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end },
    { title = "Re-arm hotkeys", fn = function() wf.armTap(); wf.notify("Hotkeys re-armed", 2, wf.TONE.ok) end },
    { title = "-" },
    { title = "Restart engine", fn = function()
        hs.execute("/bin/launchctl kickstart -k gui/$(id -u)/io.sanele.server")
        wf.notify("Whisper engine restarting…")
      end },
    { title = "Write diagnostics to log", fn = function()
        wf.diagToLog(); wf.notify("Diagnostics written to sanele.log", 3, wf.TONE.ok)
      end },
    { title = "Open log", fn = function() hs.execute("/usr/bin/open '" .. wf.LOG .. "'") end },
    { title = "-" },
    { title = "Quit Sanele", fn = function() hs.application.get("Hammerspoon"):kill() end },
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

-- ── Diagnostics ─────────────────────────────────────────────────────────
-- Returns the state string. Callable via `hs -c 'return wf.diag()'` only when the
-- ipc opt-in above is enabled; otherwise reach it through wf.diagToLog() (menu item
-- + startup), which needs no open port.
function wf.diag()
  return string.format(
    "state=%s | tap=%s | accessibility=%s | hotkeys=%d | server=%s | ipc=%s",
    wf.state,
    wf.flagWatcher and tostring(wf.flagWatcher:isEnabled()) or "nil",
    tostring(hs.accessibilityState()),
    #hs.hotkey.getHotkeys(),
    hs.execute(wf.BASH.." '"..wf.DICTATE.."' server"):gsub("%s+",""),
    io.open(wf.HOME .. "/.cache/sanele/allow-ipc") and "ON(dev)" or "off")
end
function wf.diagToLog() wf.log("diag: " .. wf.diag()) end

-- ── Launch/appearance ──────────────────────────────────────────────────
hs.autoLaunch(true)
hs.dockIcon(false)
-- Hide Hammerspoon's OWN menu bar icon. Sanele runs inside Hammerspoon, so by
-- default the user sees two icons — Hammerspoon's hammer next to Sanele's — and
-- the hammer opens a console that has nothing to do with this product. Only
-- MJShowDockIconKey was ever set, which is why the hammer survived. Setting it
-- here rather than via `defaults write` keeps it declarative: a fresh install on
-- another Mac gets the same result without a manual step.
hs.menuIcon(false)
wf.setState("idle")
wf.diagToLog()    -- diagnostics without an open ipc port
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
    wf.notify("Sanele ready — hold right ⌥ to dictate", 3, wf.TONE.ok)
  else
    wf.notify("One step left — menu bar → Grant / test microphone", 5, wf.TONE.warn)
  end
end, {"--probe"}):start()
