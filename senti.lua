-- ═══════════════════════════════════════════════════════════════════════
--  Senti — free, 100% local speech-to-text (a Wispr Flow clone)
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
-- Opt back in for live `hs -c` debugging with:  touch ~/.cache/senti/allow-ipc
if io.open(os.getenv("HOME") .. "/.cache/senti/allow-ipc") then
  require("hs.ipc")   -- developer opt-in: restores the `hs` command-line bridge
end

wf = wf or {}
wf.HOME    = os.getenv("HOME")
wf.DICTATE = wf.HOME .. "/.config/senti/senti-dictate.sh"
wf.PROMPTS = wf.HOME .. "/.config/senti/senti-prompt.sh"
wf.SESSION  = wf.HOME .. "/.config/senti/senti-session.sh"
-- Load the 2x bitmap and size it in points below. Loading the 1x file gave a
-- 22px image that Retina displays scaled up, which is why the icon looked blurry.
wf.MENUICON = wf.HOME .. "/.config/senti/menubar/mic@2x.png"
wf.COMMAND = wf.HOME .. "/.config/senti/senti-command.sh"
wf.AIKEY   = wf.HOME .. "/.config/senti/openai-key"
-- True when the AI modes have a key to use (a non-empty key file).
function wf.hasAIKey()
  local a = hs.fs.attributes(wf.AIKEY)
  return a ~= nil and a.mode == "file" and (a.size or 0) > 0
end
wf.VISION  = wf.HOME .. "/.config/senti/senti-vision.sh"
wf.CTXPRE  = wf.HOME .. "/.config/senti/senti-lib.sh"   -- run directly = prefetch context
wf.SELFILE = wf.HOME .. "/.cache/senti/selection.txt"
wf.SHOT    = wf.HOME .. "/.cache/senti/screen.png"
wf.AUTH    = wf.HOME .. "/.config/senti/senti-mic-auth"  -- AVFoundation mic-permission helper
wf.MODELSH = wf.HOME .. "/.config/senti/senti-model.sh"
wf.LOG     = wf.HOME .. "/Library/Logs/senti.log"
wf.BASH    = "/bin/bash"
wf.micOK   = false   -- cached once macOS authorizes the mic
-- Without the helper (swiftc missing or its build failed at install) the probe can never
-- answer and hold-to-talk did nothing at all. Record anyway: a denied mic still shows up
-- as an all-zero clip, which the silence gate reports.
if not hs.fs.attributes(wf.AUTH) then wf.micOK = true end

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
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [hs] " .. msg .. "\n"); f:close() end
end

-- ── UI ─────────────────────────────────────────────────────────────────
-- Menu bar uses a real template image, not an emoji in setTitle: macOS keeps
-- only the alpha channel and tints it for light/dark/active automatically, which
-- is what makes it sit correctly next to system items. State is carried by the
-- floating HUD (which is only ever visible in the non-idle states anyway).
local function menuIcon()
  local img = hs.image.imageFromPath(wf.MENUICON)
  -- 22x18pt, the size make-icon.sh renders at. Any other size makes macOS
  -- resample the bitmap, which is what blurred the old icon.
  if img then img:setSize({ w = 22, h = 18 }); img:template(true) end
  return img
end

-- ── Floating HUD pill: a small bottom-center overlay with a live waveform ─
-- Deliberately quiet: no logo and, for plain dictation, no text. The pill is
-- only on screen while you are speaking, so it should stay out of the way and
-- say one thing: "I'm hearing you". The AI modes add a short label, because
-- there the pill is the only place that says which mode a held key started.
-- The brand mark lives in the menu bar, the app icon and the toasts instead.
local HUD_H, NBARS = 34, 9
local BAR_W, BAR_PITCH = 3, 7
local BARS_SPAN = (NBARS - 1) * BAR_PITCH + BAR_W
local HUD_PAD, LABEL_W, LABEL_GAP = 20, 62, 10
local ACCENT  = { red = 0.302, green = 0.580, blue = 1.000, alpha = 1 }  -- brand blue (toasts, working)
local VOICE   = { white = 0.97, alpha = 1 }                               -- recording
local WORKING = ACCENT                                                    -- transcribing / thinking
wf.hud = { canvas = nil, timer = nil, phase = 0, tone = VOICE, barX = HUD_PAD }

-- Element indices. Named because a bare c[3] is unreadable and the waveform
-- loop appends after them — inserting an element silently shifts every access.
local I_LABEL = 3

local function hudBuild()
  local c = hs.canvas.new({ x = 0, y = 0, w = BARS_SPAN + 2 * HUD_PAD, h = HUD_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  -- No frame on these two: they fill the canvas, so resizing the canvas in
  -- hudLayout resizes the pill with it.
  c[1] = { type = "rectangle", action = "fill",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           fillColor = { red = 0.043, green = 0.043, blue = 0.055, alpha = 0.94 } }
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1 }

  c[I_LABEL] = { type = "text", text = "",
                 frame = { x = HUD_PAD - 4, y = HUD_H / 2 - 9, w = LABEL_W, h = 18 },
                 textColor = { white = 0.97, alpha = 1 }, textSize = 12,
                 textFont = "SF Pro Text" }

  for i = 1, NBARS do
    c[I_LABEL + i] = { type = "rectangle", action = "fill",
                       roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
                       fillColor = VOICE,
                       frame = { x = HUD_PAD + (i - 1) * BAR_PITCH, y = HUD_H / 2 - 1.5,
                                 w = BAR_W, h = 3 } }
  end
  return c
end

-- Size and place the pill for this turn: bars only, or label + bars.
local function hudLayout(label)
  local c = wf.hud.canvas
  local w = BARS_SPAN + 2 * HUD_PAD
  wf.hud.barX = HUD_PAD
  if label then
    w = w + LABEL_W + LABEL_GAP - 4
    wf.hud.barX = w - HUD_PAD - BARS_SPAN
  end
  local scr = hs.screen.mainScreen():frame()
  c:frame({ x = scr.x + (scr.w - w) / 2, y = scr.y + scr.h - HUD_H - 28, w = w, h = HUD_H })
  c[I_LABEL].text = label or ""
end

-- Two animations off one timer. Recording: a waveform with a centre-weighted
-- envelope, so the middle bars run taller than the edges the way real speech
-- energy does — a flat sine across all bars reads as a loading spinner, not a voice.
-- Working: a travelling wave, which says "busy" without implying it is still
-- hearing you, and always has motion somewhere on the strip so it never looks hung.
local function hudAnimate()
  local c = wf.hud.canvas
  if not c then return end
  wf.hud.phase = wf.hud.phase + 1
  local working = (wf.hud.tone == WORKING)
  for i = 1, NBARS do
    local h
    if working then
      h = 3 + 7 * (0.5 + 0.5 * math.sin(wf.hud.phase * 0.22 - i * 0.7))
    else
      -- Floor the envelope at 0.6 so the outer bars stay bars, not dots.
      local env = 0.6 + 0.4 * math.sin(math.pi * (i - 0.5) / NBARS)
      h = 3 + 15 * env * (0.5 + 0.5 * math.sin(wf.hud.phase * 0.30 + i * 0.75))
    end
    c[I_LABEL + i].frame = { x = wf.hud.barX + (i - 1) * BAR_PITCH, y = (HUD_H - h) / 2,
                             w = BAR_W, h = h }
  end
end

local function hudTint(col)
  local c = wf.hud.canvas
  wf.hud.tone = col
  for i = 1, NBARS do c[I_LABEL + i].fillColor = col end
end

function wf.hud.show(s)
  if not wf.hud.canvas then wf.hud.canvas = hudBuild() end
  local c = wf.hud.canvas
  if s == "recording" then
    hudTint(VOICE)
    -- Plain dictation shows bars only; the AI modes name themselves.
    local labels = { prompt = "Prompt", command = "Command", context = "Context" }
    hudLayout(labels[wf.mode])
  elseif s == "working" or s == "thinking" then
    hudTint(WORKING)
    hudLayout((s == "thinking") and "Thinking" or nil)
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

-- ── Toast: short messages in the same dark pill language as the HUD ──────
-- Centred text in a pill sized to fit it, sitting just above where the HUD
-- appears. One brand colour: info and success look the same, because "it
-- worked" needs no special colour. Only a warning changes anything, and it
-- changes the outline, not the text.
wf.toast = { canvas = nil, timer = nil }
local T_INFO = ACCENT
local T_OK   = ACCENT
local T_WARN = { red = 0.98, green = 0.62, blue = 0.24, alpha = 1 }
local TOAST_FONT = { name = "SF Pro Text", size = 13 }

function wf.notify(msg, secs, tone)
  secs, tone = secs or 3, tone or T_INFO
  msg = tostring(msg)
  local text = hs.styledtext.new(msg, {
    font = TOAST_FONT, color = { white = 0.97, alpha = 1 },
    paragraphStyle = { alignment = "center", lineSpacing = 3 } })
  -- Measure the real text so the pill hugs it. A fixed-width pill with
  -- left-aligned text is what made short messages look off-centre.
  local size = hs.drawing.getTextDrawingSize(text) or { w = 320, h = 18 }
  local padX, padY = 24, 12
  local W = math.max(180, math.min(560, math.ceil(size.w) + 2 * padX))
  local H = math.ceil(size.h) + 2 * padY
  local radius = math.min(H / 2, 18)
  local scr = hs.screen.mainScreen():frame()
  if wf.toast.canvas then wf.toast.canvas:delete(); wf.toast.canvas = nil end
  local c = hs.canvas.new({ x = scr.x + (scr.w - W) / 2,
                            y = scr.y + scr.h - H - 76, w = W, h = H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "fill",
           roundedRectRadii = { xRadius = radius, yRadius = radius },
           fillColor = { red = 0.043, green = 0.043, blue = 0.055, alpha = 0.94 } }
  local warn = (tone == T_WARN)
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = radius, yRadius = radius },
           strokeColor = warn and { red = 0.98, green = 0.62, blue = 0.24, alpha = 0.7 }
                               or { white = 1, alpha = 0.12 },
           strokeWidth = 1 }
  c[3] = { type = "text", text = text,
           frame = { x = padX, y = padY, w = W - 2 * padX, h = H - 2 * padY } }
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
      if wf.state == "working" then
        -- Abandon the turn: bumping the id makes its late callback drop its result
        -- instead of pasting into whatever app is focused by then.
        local abandoned = wf.turn
        wf.turn = (wf.turn or 0) + 1
        wf.log("watchdog: 'working' stuck 75s → turn abandoned, reset idle")
        -- Don't lose the user's words with the turn: give back what they had copied
        -- (command mode cleared it to read the selection), else what they said.
        local p, msg = wf.pending, "That took too long and was cancelled."
        wf.pending = nil
        if p and p.turn ~= abandoned then p = nil end   -- left over from an earlier turn
        if p and p.clip then
          wf.restoreClipboard(p.clip, hs.pasteboard.changeCount())
        elseif p and p.raw then
          wf.setPrivateClipboard(p.raw); msg = msg .. "\nWhat you said is on the clipboard."
        end
        wf.notify(msg, 5, wf.TONE.warn)
        wf.setState("idle")
      end
    end)
  elseif s == "recording" then
    wf.stuckTimer = hs.timer.doAfter(150, function()  -- no real dictation runs 2.5 min
      if wf.state == "recording" then
        -- A lost key-up or a forgotten toggle. Transcribe what was recorded instead of
        -- deleting up to 2.5 minutes of speech — but clipboard only: focus may be
        -- anywhere by now, so pasting (or rewriting a selection) would hit the wrong app.
        wf.log("watchdog: 'recording' stuck 150s → transcribing to the clipboard")
        wf.held = nil; wf.endCapture(true)
      end
    end)
  end
end

-- ── Insert text into whatever app is focused (clipboard paste) ──────────
-- Put text on the clipboard marked transient + concealed (the nspasteboard.org
-- convention) so clipboard managers and Universal Clipboard don't keep transcripts.
-- Plain setContents if that fails. Every place Senti hands words back uses this.
function wf.setPrivateClipboard(text)
  local ok, wrote = pcall(hs.pasteboard.writeAllData, {
    ["public.utf8-plain-text"] = text,
    ["org.nspasteboard.TransientType"] = "",
    ["org.nspasteboard.ConcealedType"] = "",
  })
  if not (ok and wrote) then hs.pasteboard.setContents(text) end
end

-- The window that had focus when the turn started (set in wf.record). A result that
-- arrives after the user moved to another window must not be typed there.
function wf.focusMoved()
  if not wf.focusAtStart then return false end
  local w = hs.window.focusedWindow()
  return (w and w:id()) ~= wf.focusAtStart
end

function wf.paste(text)   -- low-level: put text on the clipboard and ⌘V it
  wf.setPrivateClipboard(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
end

-- Hand text back without typing it, because focus moved during the turn.
function wf.handBack(text, why)
  wf.setPrivateClipboard(text)
  wf.log("handed back " .. #text .. " chars on the clipboard (" .. why .. ")")
  wf.notify("You switched windows, so Senti did not type it.\nIt's on the clipboard.", 5, wf.TONE.warn)
end

-- Snapshot every flavour on the clipboard, not just its text: getContents() is nil for
-- an image and flattens a file or rich text, so the old restore lost them.
-- Plain text (the common case) needs only the cheap text snapshot. Promised data is
-- skipped: reading it makes the source app render every flavour on our main thread.
local TEXT_TYPES = { ["public.utf8-plain-text"] = true, ["public.plain-text"] = true,
                     ["NSStringPboardType"] = true, ["public.utf16-external-plain-text"] = true }
function wf.saveClipboard()
  local saved = { text = hs.pasteboard.getContents() }
  local okT, types = pcall(hs.pasteboard.contentTypes)
  if not okT or type(types) ~= "table" then return saved end
  local rich = false
  for _, t in ipairs(types) do
    if t:find("^dyn%.") or t:find("promise") then return saved end
    if not TEXT_TYPES[t] then rich = true end
  end
  if rich then
    local ok, all = pcall(hs.pasteboard.readAllData)
    if ok and type(all) == "table" and next(all) then saved.all = all end
  end
  return saved
end

-- Restore after our paste, unless the user copied something new in the meantime.
function wf.restoreClipboard(saved, ourCount)
  if not saved or hs.pasteboard.changeCount() ~= ourCount then return end
  if saved.all then
    -- pcall's first value is only "didn't throw"; writeAllData's own result says whether
    -- every flavour was written (it clears first, so a failure can leave it empty).
    local ok, wrote = pcall(hs.pasteboard.writeAllData, saved.all)
    if ok and wrote then return end
  end
  if saved.text then hs.pasteboard.setContents(saved.text) end
end

function wf.insert(text)  -- dictation insert: trailing space + clipboard restore
  if not text or text:gsub("%s+","") == "" then wf.log("insert: empty, nothing to paste"); return end
  if wf.TRAILING_SPACE then text = text .. " " end
  if wf.focusMoved() then wf.handBack(text, "focus moved"); return end
  local prev = wf.saveClipboard()
  wf.paste(text)
  local ours = hs.pasteboard.changeCount()
  wf.log("insert: pasted " .. #text .. " chars")
  hs.timer.doAfter(0.5, function()   -- give slow apps time to read the clipboard before restoring
    wf.restoreClipboard(prev, ours)
  end)
end

-- Command Mode: transform the current selection (or generate at cursor) by voice.
function wf.runCommand(command, turn)
  wf.hud.show("thinking")
  local prevClip = wf.saveClipboard()
  -- If this turn is abandoned, the watchdog restores this clipboard (see setState).
  if wf.pending and wf.pending.turn == turn then wf.pending.clip = prevClip end
  hs.pasteboard.clearContents()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)      -- copy the current selection
  -- Wait for the copy to land (the change count moves) rather than a fixed delay: slow
  -- apps used to miss 0.18 s, which read as "nothing selected", and the result then
  -- overwrote a selection it never saw. No change within 0.8 s means no selection.
  local waited, poll = 0, nil
  poll = hs.timer.doEvery(0.04, function()
    waited = waited + 0.04
    if hs.pasteboard.changeCount() == before and waited < 0.8 then return end
    poll:stop()
    local sel = hs.pasteboard.getContents() or ""
    local f = io.open(wf.SELFILE, "w"); if f then f:write(sel); f:close() end
    wf.log("command: " .. #command .. " chars on " .. #sel .. " selected chars")  -- not the text itself
    wf.runScript({wf.COMMAND, "", wf.SELFILE}, command, function(exitCode, out)
      -- Stale: a newer turn may own selection.txt now; the sweep removes ours.
      if wf.staleTurn(turn) then return end
      os.remove(wf.SELFILE)                    -- selected text is the user's content; don't leave it on disk
      wf.pending = nil
      wf.setState("idle")
      wf.sweepCache()                          -- the audio of the spoken command
      out = (out or ""):gsub("%s+$", "")
      if exitCode ~= 0 or out == "" then
        wf.log("command: AI request failed (exit " .. tostring(exitCode) .. "), selection left unchanged")
        wf.restoreClipboard(prevClip, hs.pasteboard.changeCount())
        wf.notify("The command didn't run. Check your network or OpenAI key.\nYour selection is unchanged.", 5, wf.TONE.warn)
        return
      end
      if wf.focusMoved() then
        wf.restoreClipboard(prevClip, hs.pasteboard.changeCount())
        wf.handBack(out, "focus moved during command"); return
      end
      wf.paste(out)                            -- replaces the selection, or inserts at cursor
      local ours = hs.pasteboard.changeCount()
      wf.log("command: applied " .. #out .. " chars")
      hs.timer.doAfter(0.5, function() wf.restoreClipboard(prevClip, ours) end)
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
-- Sweep by PATTERN, not a hardcoded filename list: a stale full-res screenshot from
-- July survived on disk for weeks precisely because it wasn't on the old list. Any
-- top-level audio / screenshot / selection artefact is sensitive and gets removed;
-- subdirectories (sessions/, brain/), prefs (*.pref) and the allow-ipc toggle are left
-- alone. These files are same-uid readable regardless of mode, so the real protection
-- is a short on-disk life — this runs at the end of every turn, at startup, and on a
-- 60s backstop.
-- "ctx-*" are the prefetched prompt-context files (vault digest + session transcript,
-- written at key-down by senti-lib.sh). They're turn artefacts like the rest — the
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
    SENTI_HINT = wf.targetHint or "",
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
function wf.runVision(raw, kind, turn)
  wf.hud.show("thinking")
  -- Target hint + session identity ride the env via runScript; argv carries only paths/kind.
  wf.runScript({wf.VISION, "", wf.SHOT, kind}, raw, function(exitCode, out)
    -- Stale: no sweep — a newer turn may be mid-flight on capture.wav / screen.png.
    if wf.staleTurn(turn) then return end
    wf.pending = nil
    wf.setState("idle")
    if exitCode ~= 0 then
      -- Don't throw the user's words away with the failed request.
      wf.log("vision failed (exit " .. tostring(exitCode) .. ") — words left on the clipboard")
      wf.setPrivateClipboard(raw)
      wf.notify("The request failed. Check your network or OpenAI key.\nWhat you said is on the clipboard.", 5, wf.TONE.warn)
    else
      wf.insert((out or ""):gsub("%s+$", ""))
    end
    wf.sweepCache()   -- the screenshot is a picture of your screen; don't let it linger
  end)
end

-- A result belongs to the turn that started it. The 'working' watchdog abandons a turn
-- by bumping wf.turn, and its late callback must then do nothing: no paste into whatever
-- app is focused now, and no setState that would wreck a newer recording.
function wf.staleTurn(turn)
  if turn ~= nil and turn ~= wf.turn then
    wf.log("dropped a late result from an abandoned turn")
    return true
  end
  return false
end

function wf.handleTranscript(raw, turn, clipOnly)
  raw = (raw or ""):gsub("^%s+",""):gsub("%s+$","")
  if wf.staleTurn(turn) then return end
  -- Record the turn against this window's session before acting on it, so the next
  -- dictation in the SAME window can resolve back-references. Fire-and-forget.
  -- Sentinels (__WF_*__) are status, not speech — never store them as a turn.
  if raw ~= "" and not raw:match("^__WF_[%u_]+__$") and wf.sessKey ~= "" then
    -- key/label ride the env (runScript sets SENTI_SKEY/SENTI_SLABEL); argv carries
    -- only the subcommand and mode — window titles stay out of `ps`.
    wf.runScript({wf.SESSION, "note", "", "", tostring(wf.mode or "dictate")}, raw, nil)
  end
  if raw == "__WF_MIC_DEAD__" then
    -- Peak was exactly 0.000000: the mic returned pure silence, which on macOS almost
    -- always means Hammerspoon's Microphone permission is missing/revoked or the input
    -- device is muted — NOT that the user said nothing. Real turns in the log lost 50s
    -- and 78s of speech to this with zero feedback. Name the cause and open the fix.
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Your microphone captured no audio.\nCheck it isn't muted, or re-grant Microphone:\nmenu bar → Grant / test microphone", 5, wf.TONE.warn)
    -- Force a fresh permission probe on the next capture — only if there is a helper to
    -- probe with; without it a probe never answers and hold-to-talk would go dead.
    if hs.fs.attributes(wf.AUTH) then wf.micOK = false end
    return
  end
  if raw == "__WF_SERVER_DOWN__" then
    wf.setState("idle"); wf.sweepCache()
    wf.notify("Whisper engine is not running.\nMenu bar → Restart engine", 4, wf.TONE.warn)
    return
  end
  if raw == "__WF_TAP__" then   -- a brushed key, not a dictation: nothing to report
    wf.setState("idle"); wf.sweepCache()
    return
  end
  if raw == "__WF_TRANSCRIBE_FAILED__" then
    -- The engine errored or timed out. Not a muted mic: say so, or people go re-grant
    -- a permission that was fine.
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Transcription failed — the whisper engine errored or timed out.\nTry again, or menu bar → Restart engine", 5, wf.TONE.warn)
    return
  end
  if raw == "" then
    -- NEVER fail silently here. The log shows real turns where the user held the key
    -- for 50s and 78s, waited ~30s for transcription, and got NOTHING back — no sound,
    -- no alert, no text — because this branch just returned. Silent, undiagnosed
    -- failure is the single most-cited complaint about competing dictation tools;
    -- losing a minute of speech with no signal is the worst thing this app can do.
    -- Say what happened. The audio is deleted with the rest of the turn's files: there is
    -- no way to recover it from the app, so keeping it only kept speech on disk.
    -- Except after a brushed key: when key-up beats sox to the file there is no audio
    -- at all, and a hold that short was never a dictation. Long holds still alert.
    if (wf.lastHold or 1) < 0.6 then
      wf.log("transcript: empty after a " .. string.format("%.2f", wf.lastHold) .. "s tap — ignored")
      wf.setState("idle"); wf.sweepCache()
      return
    end
    wf.log("transcript: empty (silence/gated) — alerting user")
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Nothing was transcribed.\nThe mic may be muted or the audio was silent.\nMenu bar → Grant / test microphone", 4, wf.TONE.warn)
    return
  end

  if clipOnly then
    wf.setState("idle"); wf.setPrivateClipboard(raw); wf.sweepCache()
    wf.notify("Recording ran 2.5 minutes, so it was stopped.\nThe transcript is on the clipboard.", 5, wf.TONE.warn)
    return
  end
  -- Prompt, Command and Context call OpenAI with the user's own key. Without one, say
  -- so and hand the words back on the clipboard rather than typing them as if the mode
  -- had worked (and never paste raw speech over a Command selection).
  if wf.mode ~= "verbatim" and not wf.hasAIKey() then
    wf.setState("idle"); wf.setPrivateClipboard(raw); wf.sweepCache()
    wf.log("ai mode " .. tostring(wf.mode) .. ": no OpenAI key, words left on the clipboard")
    wf.notify("This mode needs your OpenAI API key in\n~/.config/senti/openai-key\nWhat you said is on the clipboard.", 6, wf.TONE.warn)
    return
  end
  -- AI modes can outlive the 75s watchdog; keep the words so it can hand them back.
  if wf.mode ~= "verbatim" then wf.pending = { turn = turn, raw = raw } end

  if wf.mode == "context" then
    wf.awaitShot(4, function(has)
      if wf.staleTurn(turn) then return end
      if has then wf.runVision(raw, "context", turn)
      else
        wf.setState("idle"); wf.sweepCache()
        wf.log("context: no screenshot — Screen Recording not granted")
        wf.notify("Context mode needs Screen Recording.\nSystem Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it", 5, wf.TONE.warn)
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end
    end)
  elseif wf.mode == "command" then
    wf.runCommand(raw, turn)           -- raw = the spoken instruction
  elseif wf.mode == "prompt" then
    wf.awaitShot(4, function(has)
      if wf.staleTurn(turn) then return end
      if has then wf.runVision(raw, "prompt", turn)   -- screen context → context-aware prompt
      else                                       -- no screen → text-only prompt path
        wf.hud.show("thinking")
        wf.runScript({wf.PROMPTS}, raw, function(exitCode, stdout)
          if wf.staleTurn(turn) then return end
          wf.pending = nil
          wf.setState("idle"); wf.sweepCache()
          if exitCode ~= 0 then
            wf.setPrivateClipboard(raw)
            wf.notify("The request failed. Check your network or OpenAI key.\nWhat you said is on the clipboard.", 5, wf.TONE.warn)
            return
          end
          wf.insert(stdout)
        end)
      end
    end)
  else
    wf.setState("idle"); wf.insert(raw); wf.sweepCache()
  end
end

function wf.record()
  wf.recStartedAt = hs.timer.secondsSinceEpoch()
  local fw = hs.window.focusedWindow()
  wf.focusAtStart = fw and fw:id() or nil
  wf.setState("recording")
  wf.log("record: mode="..tostring(wf.mode))
  hs.task.new(wf.BASH, nil, {wf.DICTATE, "start"}):start()
end

-- Prompt for / open the mic permission. `andThenRecord` = record once granted.
function wf.grantMic(andThenRecord)
  if not hs.fs.attributes(wf.AUTH) then   -- hs.task on a missing binary fails silently
    wf.notify("The microphone helper is missing.\nInstall Xcode Command Line Tools, then re-run install.sh", 5, wf.TONE.warn)
    return
  end
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
  -- No helper (checked now, not at load: it can vanish or appear after a re-install):
  -- record anyway — a denied mic still shows up as an all-zero clip.
  if wf.micOK or not hs.fs.attributes(wf.AUTH) then wf.record(); return end
  -- First use: check permission without prompting; act on the result.
  -- The probe is async. If a hold key started this and is released before the probe
  -- answers, recording now would start a capture no key can end — so don't.
  local heldAtStart = wf.held
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    wf.log("mic probe: "..out)
    if out == "AUTHORIZED" then
      wf.micOK = true
      if heldAtStart ~= nil and wf.held ~= heldAtStart then
        wf.log("mic probe answered after key-up — not recording")
      elseif wf.state == "idle" then
        wf.record()
      end
    elseif out == "NOTDETERMINED" then
      -- No recording will start, so let go of the key now; a lost key-up would
      -- otherwise leave wf.held set and swallow the next press as its "release".
      if heldAtStart ~= nil and wf.held == heldAtStart then wf.held = nil end
      wf.notify("Allow the microphone prompt,\nthen hold ⌥ again to dictate", 4)
      wf.grantMic(false)   -- triggers the macOS prompt
    else  -- DENIED / RESTRICTED
      if heldAtStart ~= nil and wf.held == heldAtStart then wf.held = nil end
      wf.grantMic(false)   -- shows the Settings guidance + opens the pane
    end
  end, {"--probe"}):start()
end

function wf.endCapture(clipOnly)
  if wf.state ~= "recording" then wf.log("endCapture ignored: state="..wf.state); return end
  wf.turn = (wf.turn or 0) + 1
  local turn = wf.turn
  wf.lastHold = hs.timer.secondsSinceEpoch() - (wf.recStartedAt or 0)
  wf.setState("working")
  wf.log("endCapture: transcribing")
  -- MUST go through runScript: senti-dictate.sh reads SENTI_SLABEL to build the
  -- whisper vocabulary hint (project name → correct identifier transcription). A bare
  -- hs.task.new carries no Senti env, so the hint silently loses its best term.
  wf.runScript({wf.DICTATE, "stop"}, "", function(_, stdout) wf.handleTranscript(stdout, turn, clipOnly) end)
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
        hs.execute("/bin/launchctl kickstart -k gui/$(id -u)/io.senti.server")
        wf.notify("Whisper engine restarting…")
      end },
    { title = "Write diagnostics to log", fn = function()
        wf.diagToLog(); wf.notify("Diagnostics written to senti.log", 3, wf.TONE.ok)
      end },
    { title = "Open log", fn = function() hs.execute("/usr/bin/open '" .. wf.LOG .. "'") end },
    { title = "-" },
    { title = "Quit Senti", fn = function() hs.application.get("Hammerspoon"):kill() end },
  }
end
if wf.bar then wf.bar:setMenu(menu) end

-- ── Hold-to-talk event tap (kept on wf.* so GC can't kill it) ───────────
-- Device-dependent modifier bits (IOKit IOLLEvent.h): NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK.
wf.SIDE_BIT = { [61] = 0x40, [54] = 0x10 }   -- right ⌥, right ⌘
function wf.sideKeyStillDown(e, code)
  local bit = wf.SIDE_BIT[code]
  if not bit then return false end
  local ok, down = pcall(function()
    return (math.tointeger(e:getRawEventData().CGEventData.flags) & bit) ~= 0
  end)
  return ok and down == true
end

function wf.armTap()
  if wf.flagWatcher then wf.flagWatcher:stop() end
  wf.flagWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
    local ok, err = pcall(function()
      local code, flags = e:getKeyCode(), e:getFlags()
      -- Release of the held key. flags.alt / flags.cmd are the left+right UNION, so with
      -- the other-side key down a release looked like "still down" and the capture never
      -- ended. Read the right-side device bit instead; Fn has none, so for it (or if the
      -- raw flags are unavailable) the next event for the held key is its release.
      if wf.held ~= nil and code == wf.held then
        if wf.sideKeyStillDown(e, code) then return end
        wf.held = nil; wf.log("tap: key " .. code .. " up"); wf.endCapture()
      elseif code == wf.HOLD_VERBATIM then
        if flags.alt == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: right⌥ down"); wf.beginCapture("verbatim")
        end
      elseif code == wf.HOLD_PROMPT then
        if flags.cmd == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: right⌘ down"); wf.snapAndCapture("prompt")
        end
      elseif code == wf.HOLD_COMMAND then
        if flags.fn == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.log("tap: Fn down"); wf.beginCapture("command")
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
    io.open(wf.HOME .. "/.cache/senti/allow-ipc") and "ON(dev)" or "off")
end
function wf.diagToLog() wf.log("diag: " .. wf.diag()) end

-- ── Launch/appearance ──────────────────────────────────────────────────
hs.autoLaunch(true)
hs.dockIcon(false)
-- Hide Hammerspoon's OWN menu bar icon. Senti runs inside Hammerspoon, so by
-- default the user sees two icons — Hammerspoon's hammer next to Senti's — and
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

-- Accessibility is what lets Senti see the hold keys and type. Without it the hotkeys
-- do nothing and nothing says why, so ask macOS to show its prompt and say it here too.
if not hs.accessibilityState() then
  wf.log("startup: Accessibility not granted")
  hs.accessibilityState(true)   -- shows the system prompt for Hammerspoon
  wf.notify("Senti needs Accessibility to type.\nSystem Settings ▸ Privacy & Security ▸\nAccessibility → turn ON Hammerspoon", 8, wf.TONE.warn)
elseif not hs.fs.attributes(wf.AUTH) then
  -- hs.task on a missing binary fails silently, so the probe below would never answer.
  wf.notify("Senti is ready, but its microphone helper is missing.\nInstall Xcode Command Line Tools, then re-run install.sh", 6, wf.TONE.warn)
else
-- Startup mic-permission probe (no prompt); nudge once if not yet authorized.
hs.task.new(wf.AUTH, function(_, out)
  out = (out or ""):gsub("%s+","")
  wf.log("startup mic probe: "..out)
  if out == "AUTHORIZED" then
    wf.micOK = true
    wf.notify("Senti is ready. Hold right ⌥ to dictate.", 3, wf.TONE.ok)
  else
    wf.notify("One step left: menu bar ▸ Grant / test microphone", 5, wf.TONE.warn)
  end
end, {"--probe"}):start()
end
