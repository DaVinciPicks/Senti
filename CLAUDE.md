# CLAUDE.md — Senti

Operating notes for Claude working in this repo. Read this first.

## What this is

**Senti** — free, 100% local macOS speech-to-text (a Wispr Flow alternative). Hold a
key, speak, cleaned text is typed into the focused app. Verbatim dictation never
leaves the Mac (whisper.cpp server bound to `127.0.0.1`). Optional AI modes
(prompt / command / context) send text — and, with screen context on, a downscaled
screenshot — to cheap cloud APIs.

- **Repo is PRIVATE + proprietary** ("all rights reserved", see `LICENSE`). It was
  briefly public/MIT, then locked down for IP protection. The owner's name and Mac
  username were scrubbed from files *and* git history — **do not reintroduce them**
  (no real names, no `/Users/<name>/…` paths in committed files; use `$HOME` / `__HOME__`).
- Flagship product under the planned **Da Vinci Tech LLC**. Freemium: free local
  dictation → paid Pro AI modes.

## Repo → live system (the mental model that matters most)

This repo is the **source**. It is not where the app runs. `./install.sh` deploys it:

| Repo file | Deploys to |
|---|---|
| `senti-*.sh`, `config.sh`, `replacements.txt`, `prompts/`, `eval/` | `~/.config/senti/` |
| `senti.lua` | `~/.hammerspoon/init.lua` |
| `com.leo.senti.plist` (with `__HOME__` substituted) | `~/Library/LaunchAgents/` |
| `app/` | `~/Applications/Senti.app` |

**Workflow: edit files in this repo, then run `./install.sh` to deploy.** Don't hand-edit
`~/.config/senti/*` or `~/.hammerspoon/init.lua` as the primary change — those are
install targets and get overwritten. (Exception: `config.sh`, `replacements.txt`,
`eval/cases.txt` are user-tunable and install **only if missing**, so a re-run never
clobbers the user's local tuning. Scripts and `senti.lua` are code — always overwritten.)

## Conventions

- **Script naming:** `senti-<role>.sh`. Env vars are prefixed **`WF_`** and the Lua global
  is **`wf`** — these are *legacy from the "Whisper Flow" name and kept intentionally*.
  Don't mass-rename them; it touches every file for no user-visible gain.
- **Secrets:** DeepSeek + OpenAI keys live at `~/.config/senti/{deepseek-key,openai-key}`
  (mode 600), gitignored. They are passed to Python via **ENV (`SENTI_KEY`), never argv** —
  so they stay out of `ps`. Keep it that way; never put a key on a command line.
- **AI output extraction:** AI modes wrap output in `<r></r>` sentinels and extract with
  perl/sed to kill model preamble. `<c></c>` wraps Best-mode candidates. Preserve these.
- **`.gitignore` guards secrets + local state:** `*-key`, `*.pref`, `eval/history.csv`.
  Verify `git status` is clean of these before any commit.

## Architecture

```
hold key ─▶ Hammerspoon (senti.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format/dictionary ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command ─▶ senti-ai.sh   ─▶ DeepSeek (→ claude fallback)   [+ operating layer]
   context/prompt+screen ─▶ senti-vision.sh ─▶ gpt-4o-mini (reads a downscaled screenshot)
```

- **Engine:** `whisper-cpp` (brew) kept warm in Metal by launchd `com.leo.senti`
  (`senti-serve.sh`). base.en (Fast ~0.2s) / large-v3-turbo-q5 (Accurate). Model choice
  in `~/.cache/senti/model.pref` via `senti-model.sh`.
- **Recording:** `sox -d` → 16 kHz mono WAV, stopped with **SIGINT** (finalizes the header).
- **AI text:** `senti-ai.sh` → DeepSeek `deepseek-chat` → falls through to `claude` CLI.
  Prepends the reusable operating layer (`prompts/operating.md`) when `WF_OPERATING_LAYER=1`.
- **AI vision:** `senti-vision.sh` → **gpt-4o-mini** (~2.7s). sips-downscales the retina
  screenshot first. (gpt-5-nano was rejected — 30s of reasoning latency.)
- **Prompt intelligence:** `senti-prompt.sh` Fast = few-shot exemplars + deconstruct framing;
  Best (`WF_PROMPT_BEST=1`) = N candidates → `senti-judge.sh` picks/merges. `senti-eval.sh`
  is the offline harness (scores `eval/cases.txt`, A/B via env, history in `eval/history.csv`).

## Modes / hotkeys

| Gesture | Mode |
|---|---|
| Hold **right ⌥** | Dictate (verbatim, 100% local) |
| Hold **right ⌘** | Prompt (rough idea → optimized prompt; reads a screenshot for context) |
| Hold **Fn (🌐)** | Command (transform selected text by voice) |
| **⌃⌥V** | Context (screenshot + voice → context-aware reply/edit) |
| `⌃⌥D` / `⌃⌥P` / `⌃⌥C` | hands-free toggle versions |

Three macOS permissions on **Hammerspoon**: Accessibility (type), Microphone (record),
Screen Recording (context/vision).

## Gotchas (these cost real time — respect them)

- **Mic TCC:** sox uses CoreAudio-HAL, which macOS *silently mutes* (peak `0.000000`)
  when Hammerspoon lacks Microphone permission — no prompt. Fix path is the Swift/AVFoundation
  helper `senti-mic-auth.swift` (`--probe` / `--request`), which triggers the real TCC prompt.
- **`hs.eventtap` must live on a global** (`wf.flagWatcher`) or Lua GC collects it and
  hold-to-talk silently dies. A 5s watchdog re-arms it. Don't make it file-local.
- **macOS ships bash 3.2:** referencing an empty array under `set -u` throws. Use
  `"${ARR[@]+"${ARR[@]}"}"`. sed/awk are **BSD**, not GNU — no `-i ''`-free in-place, no `\U`, etc.
- **No right-Control key** on MacBooks (keycode 62 doesn't fire) — command mode uses **Fn (63)**.
- **Silence gate fails open:** only skip a clip when the peak is *confidently* below threshold;
  an empty/unparsed peak must transcribe, not drop. (Kills Whisper's "Thank you." hallucination
  without eating real speech.)
- **Image downscale uses `sips`**, not PIL — `/usr/bin/python3` has no Pillow.
- **`$HOME` may contain a space:** quote every path in `hs.execute(...)`; the plist uses a
  `__HOME__` placeholder that `install.sh` substitutes (never hard-code a home path).

## Test / debug

```bash
bash ~/.config/senti/senti-dictate.sh server   # → server up/down
hs -c 'return wf.diag()'                        # state / eventtap / mic / model
tail -f ~/Library/Logs/senti.log               # runtime log
WF_PROMPT_BEST=1 bash ~/.config/senti/senti-eval.sh best   # A/B the prompt strategy
```

State machine has a watchdog: `working` stuck 75s → idle; `recording` stuck 150s → cancel
sox + reset. If hold-to-talk feels dead, check `wf.diag()` for the eventtap first.

## Commit conventions

- Terse, imperative subject describing the *behavior* change (see `git log` for the house style).
- **Never** commit a key, a `*.pref`, `eval/history.csv`, or any real name / user path.
- Update `README.md` when the mode set, permissions, or install steps change.

## Where the rest of the context lives

- User-facing: `README.md`. Go-to-market: `docs/marketing-italy.md`.
- Second brain (Obsidian): the `Senti` effort note + `Da Vinci Tech LLC` note.
- Claude memory: `whisper-flow-local-dictation-2026-07-03.md` (has the full audited state).
