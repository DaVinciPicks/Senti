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
- **Secrets:** one OpenAI key at `~/.config/senti/openai-key` (mode 600), gitignored.
- **The argv rule (load-bearing):** the key **and every piece of user speech** travel in
  the **environment (`SENTI_IN`), never argv** — `ps -Ao args` is readable by every process
  on the box. This applies at *every* layer: `senti.lua` → script (via `hs.task:setEnvironment`),
  script → script (`SENTI_IN="$X" bash …`), and script → python. Fixing only the innermost
  call is the bug that shipped once already — the wrapper's own command line leaked.
  `senti-selftest.sh` asserts it with a canary. **When writing that assertion, never pipe the
  canary into `grep`** — grep's own argv then contains it and `ps` catches the test itself
  (a false positive that flaps). Snapshot `ps` into a variable and match with a shell `case`.
- **Cache is sensitive:** `~/.cache/senti/` holds the raw audio of what was just said, a
  full-res screenshot, and any selected text. `wf.sweepCache()` clears it at the end of every
  turn, on a 60s backstop, and at launch. Don't add a new cache artefact without adding it to
  `wf.SWEEPABLE`.
- **Session memory:** keyed on the focused **window id**, not the app — several Claude Code
  terminals are all "Terminal" but are different work. The window title already carries the
  project and current task (`senti — ⠐ Evaluate software… — claude`), so working context is
  free: no screenshots, no API call, nothing leaves the Mac. Files are mode 600 under a 700
  dir and expire after `WF_SESSION_TTL_H` (24h).
- **AI output extraction:** AI modes wrap output in `<r></r>` sentinels and extract with
  perl/sed to kill model preamble. Preserve these.
- **`.gitignore` guards secrets + local state:** `*-key`, `*.pref`, `eval/history.csv`.
  Verify `git status` is clean of these before any commit.

## Architecture

```
hold key ─▶ Hammerspoon (senti.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format/dictionary ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command ─▶ senti-ai.sh   ─▶ gpt-5.6-luna   [+ operating layer]
   context/prompt+screen ─▶ senti-vision.sh ─▶ gpt-5.6-luna (reads a downscaled screenshot)
   prompt mode also ─▶ senti-target.sh ─▶ prompts/models/*.md (tailor to the destination model)
                   └─▶ senti-session.sh ─▶ ~/.cache/senti/sessions/<window-id>.tsv  (per-window memory)
```

**Script map** (all deploy to `~/.config/senti/`):

| Script | Role |
|---|---|
| `senti-dictate.sh` | record / transcribe / clean — the only path that stays 100% local |
| `senti-ai.sh` | the single shared OpenAI text call |
| `senti-vision.sh` | screenshot + instruction → text |
| `senti-prompt.sh` | rough idea → optimised prompt (fallback path — see path parity) |
| `senti-command.sh` | transform selected text by voice |
| `senti-judge.sh` | prompt quality: legacy 0-10 `score` + discriminating pairwise `compare` |
| `senti-target.sh` | frontmost app → which model's guidance digest to inject |
| `senti-session.sh` | per-window session memory (`note` / `recall` / `sweep`) |
| `senti-brain.sh` | Obsidian vault → capped project digest (+ lazy luna refresh) |
| `senti-eval.sh` | offline harness over `eval/cases.txt` |
| `senti-selftest.sh` | the full check suite — run before believing anything works |
| `senti-model.sh` | Fast/Accurate whisper model switch |
| `app/make-icon.sh` | SVG → resvg → iconutil (no Pillow, no Python) |

- **Engine:** `whisper-cpp` (brew) kept warm in Metal by launchd `com.leo.senti`
  (`senti-serve.sh`). base.en (Fast ~0.2s) / large-v3-turbo-q5 (Accurate). Model choice
  in `~/.cache/senti/model.pref` via `senti-model.sh`.
- **Recording:** `sox -d` → 16 kHz mono WAV, stopped with **SIGINT** (finalizes the header).
- **AI text + vision:** both go to **`gpt-5.6-luna`** (`senti-ai.sh` / `senti-vision.sh`).
  One provider, one key, no fallback chain. Text runs at `reasoning_effort: none`, vision
  and the judge at `low`. Measured on this Mac (see `config.sh` for the full table):
  luna text ≈ $0.0005/call, vision ≈ $0.0004 — vs gpt-4o-mini vision at 3.3s, **37k tokens**
  and $0.0056 (it tokenizes images far more expensively).
  - `minimal` effort is **rejected** by gpt-5.x — valid values are `none|low|medium|high|xhigh`.
  - `none` measured 2.2x cheaper and 1.8x faster than `low` at an identical eval score on the
    prompt-rewrite task: rewriting is transformation, not reasoning. Judging candidates *is*
    reasoning, so `senti-judge.sh` overrides to `low`.
  - Reasoning tokens count against `max_completion_tokens` — leave headroom or you get an
    empty string back with no error.
  - **Output dominates cost** (~6x input price), so trimming what the model *writes* beats
    trimming what you send. Prompt caching does NOT engage here: our prompt is ~650 tokens,
    under OpenAI's 1024-token cache minimum.
  - Prepends `prompts/operating.md` when `WF_OPERATING_LAYER=1`.
- **Model-aware prompting:** `senti-target.sh` maps the frontmost app (free, local, no
  extra API call) to a knowledge file in `prompts/models/` and injects only that file's
  `## Inject` digest (~900B). Injecting the full research prose instead cost 4.5KB and
  pushed prompt mode to 9.9s — keep the digests small.
- **Prompt intelligence:** one call, context-heavy. Both prompt paths assemble: shared craft
  (`prompts/prompt-craft.md`) + vault digest (`senti-brain.sh`) + session memory
  (`senti-session.sh`) + target-model guidance (`senti-target.sh`). Best mode was DELETED
  2026-08-09 — it was unreachable from the live path, never once measured better than one
  call, and bet 2x latency on sampling variance instead of context quality. Don't rebuild it.
- **Second brain (Obsidian):** `senti-brain.sh` maps the window-title project to a vault note
  (allowlist: `Efforts/Active` + `Atlas/DaVinci Bets`; exceptions in `brain-map.txt`), digests
  it (`## Senti` section wins, else `## For future Claude`, else first lines), caps at
  `WF_BRAIN_MAX`, logs every injection. A lazy background luna call (~$0.001) writes a tighter
  digest to `~/.cache/senti/brain/` — refreshed only when stale AND the project is actually
  used, so there's no cron and untouched projects are never sent anywhere. The digest DOES
  ride the API call: that's the feature and the risk — never widen the allowlist to `People/`
  or the vault root, and keep the privacy self-test checks passing.
- **Eval:** `senti-eval.sh` scores `eval/cases.txt` via `senti-judge.sh score` (absolute 0-10 —
  saturates around 8, fine for regression, useless for ranking); `senti-judge.sh compare` is
  the discriminating pairwise judge (order-swapped, disagreement = TIE) for real A/Bs.

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
bash ~/.config/senti/senti-selftest.sh          # full suite: engine, config, keys, icons, live API, ps-leak, sessions, brain
bash ~/.config/senti/senti-dictate.sh server    # → server up/down
hs -c 'return wf.diag()'                        # state / eventtap / mic / model
tail -f ~/Library/Logs/senti.log                # runtime log
bash ~/.config/senti/senti-eval.sh baseline        # score the 8 eval cases
```

`hs -c` **hangs if Hammerspoon isn't running** (there's no IPC peer) — that looks like a
broken init.lua but usually isn't. Check `pgrep -x Hammerspoon` and `luac -p ~/.hammerspoon/init.lua`
before debugging the Lua. Never run `hs -c 'hs.reload()'` and wait on it: reload tears down
the IPC socket mid-call and the CLI blocks forever.

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
