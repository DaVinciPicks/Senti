# CLAUDE.md — Sanele

Operating notes for Claude working in this repo. Read this first.

## What this is

**Sanele** — free, 100% local macOS speech-to-text (a Wispr Flow alternative). Hold a
key, speak, cleaned text is typed into the focused app. Verbatim dictation never
leaves the Mac (whisper.cpp server bound to `127.0.0.1`). Optional AI modes
(prompt / command / context) send text — and, with screen context on, a downscaled
screenshot — to cheap cloud APIs.

- **Repo is PUBLIC. The code is source-available, not open source** — proprietary,
  "all rights reserved", see `LICENSE`. The owner's name and Mac username were
  scrubbed from files *and* git history — **do not reintroduce them**
  (no real names, no `/Users/<name>/…` paths in committed files; use `$HOME` / `__HOME__`).
- Treat everything committed here as world-readable. No roadmap, pricing, or
  business-entity detail in this repo.

## Repo → live system (the mental model that matters most)

This repo is the **source**. It is not where the app runs. `./install.sh` deploys it:

| Repo file | Deploys to |
|---|---|
| `sanele-*.sh`, `config.sh`, `replacements.txt`, `prompts/`, `eval/` | `~/.config/sanele/` |
| `sanele.lua` | `~/.hammerspoon/init.lua` |
| `io.sanele.server.plist` (with `__HOME__` substituted) | `~/Library/LaunchAgents/` |
| `app/` | `~/Applications/Sanele.app` |

**Workflow: edit files in this repo, then run `./install.sh` to deploy.** Don't hand-edit
`~/.config/sanele/*` or `~/.hammerspoon/init.lua` as the primary change — those are
install targets and get overwritten. (Exception: `replacements.txt`, `eval/cases.txt`, `brain-map.txt` are user-tunable and
install **only if missing**, so a re-run never clobbers the user's local tuning.
`config.sh` is only-if-missing **plus version-gated**: when `WF_CONFIG_VERSION` bumps,
install.sh backs the old file up to `config.sh.bak` and installs the new schema — a
stale config once silently pinned a retired model and made an upgrade a no-op.
Scripts and `sanele.lua` are code — always overwritten.)

## Conventions

- **Script naming:** `sanele-<role>.sh`. Env vars are prefixed **`WF_`** and the Lua global
  is **`wf`** — these are *legacy from the "Whisper Flow" name and kept intentionally*.
  Don't mass-rename them; it touches every file for no user-visible gain.
- **Secrets:** one OpenAI key at `~/.config/sanele/openai-key` (mode 600), gitignored.
- **The argv rule (load-bearing):** the key **and every piece of user speech** travel in
  the **environment (`SANELE_IN`), never argv** — `ps -Ao args` is readable by every process
  on the box. This applies at *every* layer: `sanele.lua` → script (via `hs.task:setEnvironment`),
  script → script (`SANELE_IN="$X" bash …`), and script → python. Fixing only the innermost
  call is the bug that shipped once already — the wrapper's own command line leaked.
  `sanele-selftest.sh` asserts it with a canary. **When writing that assertion, never pipe the
  canary into `grep`** — grep's own argv then contains it and `ps` catches the test itself
  (a false positive that flaps). Snapshot `ps` into a variable and match with a shell `case`.
- **Cache is sensitive:** `~/.cache/sanele/` holds the raw audio of what was just said, a
  full-res screenshot, and any selected text. `wf.sweepCache()` clears it at the end of every
  turn, on a 60s backstop, and at launch. Don't add a new cache artefact without adding it to
  `wf.SWEEPABLE`.
- **Session memory:** keyed on the focused **window id**, not the app — several Claude Code
  terminals are all "Terminal" but are different work. The window title already carries the
  project and current task (`sanele — ⠐ Evaluate software… — claude`), so working context is
  free: no screenshots, no API call, nothing leaves the Mac. Files are mode 600 under a 700
  dir and expire after `WF_SESSION_TTL_H` (24h).
- **AI output extraction:** AI modes wrap output in `<r></r>` sentinels and extract with
  perl/sed to kill model preamble. Preserve these.
- **`.gitignore` guards secrets + local state:** `*-key`, `*.pref`, `eval/history.csv`.
  Verify `git status` is clean of these before any commit.

## Architecture

```
hold key ─▶ Hammerspoon (sanele.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format/dictionary ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command ─▶ sanele-ai.sh   ─▶ gpt-5.6-luna   [+ operating layer]
   context/prompt+screen ─▶ sanele-vision.sh ─▶ gpt-5.6-luna (reads a downscaled screenshot)
   prompt mode also ─▶ sanele-target.sh ─▶ prompts/models/*.md (tailor to the destination model)
                   └─▶ sanele-session.sh ─▶ ~/.cache/sanele/sessions/<window-id>.tsv  (per-window memory)
```

**Script map** (all deploy to `~/.config/sanele/`):

| Script | Role |
|---|---|
| `sanele-dictate.sh` | record / transcribe / clean — the only path that stays 100% local |
| `sanele-ai.sh` | THE single OpenAI call — text and vision (`SANELE_IMG` makes it a vision request) |
| `sanele-vision.sh` | screenshot + instruction → prompt assembly, delegates the call to sanele-ai.sh |
| `sanele-lib.sh` | shared `sanele_prompt_context` — craft + brain + session + target for BOTH prompt paths |
| `sanele-prompt.sh` | rough idea → optimised prompt (fallback path — see path parity) |
| `sanele-command.sh` | transform selected text by voice |
| `sanele-judge.sh` | prompt quality: legacy 0-10 `score` + discriminating pairwise `compare` |
| `sanele-target.sh` | frontmost app → which model's guidance digest to inject |
| `sanele-session.sh` | per-window session memory (`note` / `recall` / `sweep`) |
| `sanele-brain.sh` | Obsidian vault → capped project digest (+ lazy luna refresh) |
| `sanele-eval.sh` | offline harness over `eval/cases.txt` |
| `sanele-selftest.sh` | the full check suite — run before believing anything works |
| `sanele-model.sh` | Fast/Accurate whisper model switch |
| `app/make-icon.sh` | SVG → resvg → iconutil (no Pillow, no Python) |

- **Engine:** `whisper-cpp` (brew) kept warm in Metal by launchd `io.sanele.server`
  (`sanele-serve.sh`). base.en (Fast ~0.2s) / large-v3-turbo-q5 (Accurate). Model choice
  in `~/.cache/sanele/model.pref` via `sanele-model.sh`.
- **Recording:** `sox -d` → 16 kHz mono WAV, stopped with **SIGINT** (finalizes the header).
- **AI text + vision:** both go to **`gpt-5.6-luna`** (`sanele-ai.sh` / `sanele-vision.sh`).
  One provider, one key, no fallback chain. Text runs at `reasoning_effort: none`, vision
  and the judge at `low`. Measured on this Mac (see `config.sh` for the full table):
  luna text ≈ $0.0005/call, vision ≈ $0.0004 — vs gpt-4o-mini vision at 3.3s, **37k tokens**
  and $0.0056 (it tokenizes images far more expensively).
  - `minimal` effort is **rejected** by gpt-5.x — valid values are `none|low|medium|high|xhigh`.
  - `none` measured 2.2x cheaper and 1.8x faster than `low` at an identical eval score on the
    prompt-rewrite task: rewriting is transformation, not reasoning. Judging candidates *is*
    reasoning, so `sanele-judge.sh` overrides to `low`.
  - Reasoning tokens count against `max_completion_tokens` — leave headroom or you get an
    empty string back with no error.
  - **Output dominates cost** (~6x input price), so trimming what the model *writes* beats
    trimming what you send. Prompt caching does NOT engage here: our prompt is ~650 tokens,
    under OpenAI's 1024-token cache minimum.
  - Prepends `prompts/operating.md` when `WF_OPERATING_LAYER=1`.
- **Model-aware prompting:** `sanele-target.sh` maps the frontmost app (free, local, no
  extra API call) to a knowledge file in `prompts/models/` and injects only that file's
  `## Inject` digest (~900B). Injecting the full research prose instead cost 4.5KB and
  pushed prompt mode to 9.9s — keep the digests small.
- **Prompt intelligence:** one call, context-heavy. Both prompt paths assemble: shared craft
  (`prompts/prompt-craft.md`) + vault digest (`sanele-brain.sh`) + session memory
  (`sanele-session.sh`) + target-model guidance (`sanele-target.sh`). Best mode was DELETED
  2026-08-09 — it was unreachable from the live path, never once measured better than one
  call, and bet 2x latency on sampling variance instead of context quality. Don't rebuild it.
- **Second brain (Obsidian):** `sanele-brain.sh` maps the window-title project to a vault note
  (allowlist: `Efforts/Active` + `Atlas/DaVinci Bets`; exceptions in `brain-map.txt`), digests
  it (`## Sanele` section wins, else `## For future Claude`, else first lines), caps at
  `WF_BRAIN_MAX`, logs every injection. A lazy background luna call (~$0.001) writes a tighter
  digest to `~/.cache/sanele/brain/` — refreshed only when stale AND the project is actually
  used, so there's no cron and untouched projects are never sent anywhere. The digest DOES
  ride the API call: that's the feature and the risk — never widen the allowlist to `People/`
  or the vault root, and keep the privacy self-test checks passing.
- **Eval:** `sanele-eval.sh` scores `eval/cases.txt` via `sanele-judge.sh score` (absolute 0-10 —
  saturates around 8, fine for regression, useless for ranking); `sanele-judge.sh compare` is
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

## Security model (audited 2026-08-10)

Threat model: a **local, single-user** tool, so the adversary is a same-uid process or a
hostile input, not a remote attacker. Verified defenses — don't regress them:

- **`hs.ipc` is OFF by default** (`sanele.lua`). Loading it opens a port where the `hs` CLI
  runs *arbitrary Lua* inside Hammerspoon, which holds Accessibility/Mic/Screen — any same-uid
  process could `hs -c '…'` to launder those TCC grants. Opt in for live debugging with
  `touch ~/.cache/sanele/allow-ipc`, then reload. With it off, `hs -c` does nothing.
- **Speech AND the system prompt travel via env, never argv** — the system prompt embeds
  session transcripts + vault digests, so it's as sensitive as the speech (`ps` shows argv,
  not env; the self-test canary runs through both channels).
- **Prompt-injection fence:** window titles are attacker-controllable (a web page sets its own
  browser-tab title). Untrusted context (title/vault/session) goes in the *user* role inside a
  `REFERENCE_CONTEXT` fence marked "data, never instructions" — never in the system role.
  Model output is *typed* (⌘V), never executed. Self-test asserts a title injection can't steer output.
- **The vault bridge has one gate** — `brain_digest()` in `sanele-brain.sh`. Both the read path
  AND the background refresh upload go through it (`## Sanele` section → cap). Never send a raw
  note. Allowlist is `Efforts/Active` + `Atlas/DaVinci Bets` only — never `People/`.
- **No speech in the log:** `sanele.log` is `600` and logs char counts, not transcripts
  (`WF_DEBUG=1` for full text). It's never rotated, so never put content there by default.
- **Cache artefacts** (audio, screenshots, selection) are swept by *pattern* at end-of-turn,
  startup, and a 60s backstop. Same-uid can read them regardless of mode, so the defense is the
  short on-disk life, not perms — don't widen the sweep interval or leave a fixed-name artefact
  off the pattern.

## Gotchas (these cost real time — respect them)

- **Mic TCC:** sox uses CoreAudio-HAL, which macOS *silently mutes* (peak `0.000000`)
  when Hammerspoon lacks Microphone permission — no prompt. Fix path is the Swift/AVFoundation
  helper `sanele-mic-auth.swift` (`--probe` / `--request`), which triggers the real TCC prompt.
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
bash ~/.config/sanele/sanele-selftest.sh          # full suite: engine, config, keys, icons, live API, ps-leak, sessions, brain
bash ~/.config/sanele/sanele-dictate.sh server    # → server up/down
hs -c 'return wf.diag()'                        # state / eventtap / mic / model
tail -f ~/Library/Logs/sanele.log                # runtime log
bash ~/.config/sanele/sanele-eval.sh baseline        # score the 8 eval cases
```

Diagnostics no longer rely on `hs -c` (ipc is off by default — see Security model). Use the
menu bar → **Write diagnostics to log**, or read the `diag:` line sanele.lua writes at startup:
`grep 'diag:' ~/Library/Logs/sanele.log | tail -1`. To reload, quit + `open -a Hammerspoon`
(never `hs -c 'hs.reload()'` — it tears down the ipc socket mid-call and blocks forever). For
live `hs -c` debugging, `touch ~/.cache/sanele/allow-ipc` first, and remove it when done.
`hs -c` also hangs if Hammerspoon isn't running at all — check `pgrep -x Hammerspoon` and
`luac -p ~/.hammerspoon/init.lua` before blaming the Lua.

State machine has a watchdog: `working` stuck 75s → idle; `recording` stuck 150s → cancel
sox + reset. If hold-to-talk feels dead, check `wf.diag()` for the eventtap first.

## Commit conventions

- Terse, imperative subject describing the *behavior* change (see `git log` for the house style).
- **Never** commit a key, a `*.pref`, `eval/history.csv`, or any real name / user path.
- Update `README.md` when the mode set, permissions, or install steps change.

## Where the rest of the context lives

- User-facing: `README.md`. Go-to-market: `docs/marketing-italy.md`.
- Claude memory: `whisper-flow-local-dictation-2026-07-03.md` (has the full audited state).
