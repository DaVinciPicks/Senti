# CLAUDE.md — Senti

Operating notes for Claude working in this repo. Read this first.

## What this is

**Senti** — free, 100% local macOS speech-to-text (a Wispr Flow alternative). Hold a
key, speak, cleaned text is typed into the focused app. Verbatim dictation never
leaves the Mac (whisper.cpp server bound to `127.0.0.1`). Optional AI modes
(prompt / command / context) send text — and, with screen context on, a downscaled
screenshot — to cheap cloud APIs.

- **Repo is PRIVATE today (GitHub, verified 2026-10-17) but written as if public: the code is
  source-available, not open source** — proprietary,
  "all rights reserved", see `LICENSE`. The owner's name and Mac username were
  scrubbed from files *and* git history — **do not reintroduce them**
  (no real names, no `/Users/<name>/…` paths in committed files; use `$HOME` / `__HOME__`).
- Treat everything committed here as world-readable. No roadmap, pricing, or
  business-entity detail in this repo.
- **The prompting knowledge base is NOT in this repo.** `prompts/` is gitignored and
  lives in a separate private repo (named in `CLAUDE.local.md`). It is the paid artifact — the app
  is the free on-ramp, the knowledge is what people subscribe to. Clone it beside this
  repo (or symlink) so `install.sh` can deploy it; without it the AI modes run with no
  craft layer and no model guidance, and install.sh says so. **Never commit `prompts/`
  back into this repo** — it was purged from history on 2026-08-19, and re-adding it
  would republish the asset.

## Repo → live system (the mental model that matters most)

This repo is the **source**. It is not where the app runs. `./install.sh` deploys it:

| Repo file | Deploys to |
|---|---|
| `senti-*.sh`, `config.sh`, `replacements.txt`, `prompts/`, `eval/` | `~/.config/senti/` |
| `senti.lua` | `~/.hammerspoon/init.lua` |
| `io.senti.server.plist` (with `__HOME__` substituted) | `~/Library/LaunchAgents/` |
| `app/` | `~/Applications/Senti.app` |

**Workflow: edit files in this repo, then run `./install.sh` to deploy.** Don't hand-edit
`~/.config/senti/*` or `~/.hammerspoon/init.lua` as the primary change — those are
install targets and get overwritten. (Exception: `replacements.txt`, `eval/cases.txt`, `brain-map.txt` are user-tunable and
install **only if missing**, so a re-run never clobbers the user's local tuning.
`config.sh` is only-if-missing **plus version-gated**: when `WF_CONFIG_VERSION` bumps,
install.sh backs the old file up to `config.sh.v<old>.bak` and installs the new schema — a
stale config once silently pinned a retired model and made an upgrade a no-op.
Scripts and `senti.lua` are code — always overwritten.)

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
  the patterns in `wf.sweepSensitive`.
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
   prompt/command ─▶ senti-ai.sh   ─▶ gpt-6-luna   [+ operating layer]
   context/prompt+screen ─▶ senti-vision.sh ─▶ gpt-6-luna (reads a downscaled screenshot)
   prompt mode also ─▶ senti-target.sh ─▶ prompts/models/*.md (tailor to the destination model)
                   └─▶ senti-session.sh ─▶ ~/.cache/senti/sessions/<window-id>.tsv  (per-window memory)
```

**Script map** (all deploy to `~/.config/senti/`):

| Script | Role |
|---|---|
| `senti-dictate.sh` | record / transcribe / clean — the only path that stays 100% local |
| `senti-ai.sh` | THE single OpenAI call — text and vision (`SENTI_IMG` makes it a vision request) |
| `senti-vision.sh` | screenshot + instruction → prompt assembly, delegates the call to senti-ai.sh |
| `senti-lib.sh` | shared `senti_prompt_context` — craft + brain + session + target for BOTH prompt paths |
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

- **Engine:** `whisper-cpp` (brew) kept warm in Metal by launchd `io.senti.server`
  (`senti-serve.sh`). base.en (Fast ~0.2s) / large-v3-turbo-q5 (Accurate). Model choice
  in `~/.cache/senti/model.pref` via `senti-model.sh`.
- **Recording:** `sox -d` → 16 kHz mono WAV, stopped with **SIGINT** (finalizes the header).
- **AI text + vision:** both go to **`gpt-6-luna`** (`senti-ai.sh` / `senti-vision.sh`) since
  2026-10-17: $0.10/$0.50 per 1M vs gpt-5.6-luna's $0.20/$1.20, and it beat 5.6-luna 5-0-3
  pairwise on the 8 eval cases while costing ~1/3 per text call at the same latency.
  One provider, one key, no fallback chain. Text runs at `reasoning_effort: none`, vision
  and the judge at `low`. Earlier measurements (5.6-luna, with the KB layer): text ≈
  $0.0005/call, vision ≈ $0.0004 — gpt-6-luna should be roughly a third to a half of that
  (estimated from price and the A/B, not yet measured with the KB layer); vs gpt-4o-mini
  vision at 3.3s, **37k tokens** and $0.0056 (it tokenizes images far more expensively).
  - `minimal` effort is **rejected** by gpt-5.x and gpt-6 — gpt-6-luna takes
    `none|low|medium|high|xhigh|max` (default `medium`, so always pass one).
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
  (allowlist is narrow and configured locally; exceptions in `brain-map.txt`), digests
  it (`## Senti` section wins, else `## For future Claude`, else first lines), caps at
  `WF_BRAIN_MAX`, logs every injection. A lazy background luna call (~$0.001) writes a tighter
  digest to `~/.cache/senti/brain/` — refreshed only when stale AND the project is actually
  used, so there's no cron and untouched projects are never sent anywhere. The digest DOES
  ride the API call: that's the feature and the risk — never widen the allowlist to `People/`
  or the vault root, and keep the privacy self-test checks passing. Never commit a real vault path here.
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

## Security model (audited 2026-08-10, re-audited 2026-10-17)

Threat model: a **local, single-user** tool, so the adversary is a same-uid process or a
hostile input, not a remote attacker. Verified defenses — don't regress them:

- **`hs.ipc` is OFF by default** (`senti.lua`). Loading it opens a port where the `hs` CLI
  runs *arbitrary Lua* inside Hammerspoon, which holds Accessibility/Mic/Screen — any same-uid
  process could `hs -c '…'` to launder those TCC grants. Opt in for live debugging with
  `touch ~/.cache/senti/allow-ipc`, then reload. With it off, `hs -c` does nothing.
  This is NOT a same-uid boundary: same-uid code can create that flag or edit the deployed
  scripts Hammerspoon runs, and so already owns its TCC grants. It closes a casual port only.
- **Speech AND the system prompt travel via env, never argv** — the system prompt embeds
  session transcripts + vault digests, so it's as sensitive as the speech (`ps` shows argv,
  not env; the self-test canary runs through both channels).
- **Prompt-injection fence:** window titles are attacker-controllable (a web page sets its own
  browser-tab title). Untrusted context (title/vault/session) goes in the *user* role inside a
  `REFERENCE_CONTEXT` fence marked "data, never instructions" — never in the system role.
  Model output is *typed* (⌘V), never executed. The fence brackets are stripped from the
  untrusted body so a title cannot close it early. Self-test asserts both (with a heavy-intent
  probe — a light idea never sends the title, so it proved nothing).
- **The vault bridge has one gate** — `brain_digest()` in `senti-brain.sh`. Both the read path
  AND the background refresh upload go through it (`## Senti` section → cap). Never send a raw
  note. Allowlist is `Efforts/Active` + `Atlas/DaVinci Bets` only — never `People/` — and
  `brain-map.txt` entries obey it too (no `..`, no absolute paths, no escaping symlinks). The
  key-down prefetch never triggers the background refresh upload; only a real prompt turn can.
- **Verbatim stays local:** verbatim turns are never written to session memory, because
  recall rides prompt-mode API calls. Pasted text is marked transient + concealed so clipboard
  managers skip it; Universal Clipboard (Handoff) can still sync it — no public opt-out here.
- **Known, accepted:** whisper-server's `/load` endpoint is unauthenticated (CORS `*`), so any
  local account or a page reaching 127.0.0.1:8090 can make it load a bad model and exit;
  launchd restarts it. Denial of service only — it cannot read audio.
- **No speech in the log:** `senti.log` is `600` and logs char counts, not transcripts
  (`WF_DEBUG=1` for full text). It's never rotated, so never put content there by default —
  window titles included (bias and brain lines log counts and note names, not the title).
- **Cache artefacts** (audio, screenshots, selection) are swept by *pattern* at end-of-turn,
  startup, and a 60s backstop. Same-uid can read them regardless of mode, so the defense is the
  short on-disk life, not perms — don't widen the sweep interval or leave a fixed-name artefact
  off the pattern.

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
- **A quick tap can orphan sox:** a backgrounded sox starts with SIGINT *ignored* until it
  installs its handler, so key-up landing within ms of key-down loses the INT. sox then records
  forever into a `capture.wav` the sweep has unlinked (2026-10-17: three 8-day orphans, ~35 GB
  invisible to `du`, mic held open). `stop_sox` re-sends INT then KILLs; `reap_orphans` (keyed
  on the WAV path, not the pidfile) clears leftovers on every `start`/`cancel`. Census hidden
  disk with `lsof +L1`.
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

Diagnostics no longer rely on `hs -c` (ipc is off by default — see Security model). Use the
menu bar → **Write diagnostics to log**, or read the `diag:` line senti.lua writes at startup:
`grep 'diag:' ~/Library/Logs/senti.log | tail -1`. To reload, quit + `open -a Hammerspoon`
(never `hs -c 'hs.reload()'` — it tears down the ipc socket mid-call and blocks forever). For
live `hs -c` debugging, `touch ~/.cache/senti/allow-ipc` first, and remove it when done.
`hs -c` also hangs if Hammerspoon isn't running at all — check `pgrep -x Hammerspoon` and
`luac -p ~/.hammerspoon/init.lua` before blaming the Lua. On 2026-10-17 it hung even with
ipc on (`diag: ipc=ON(dev)`). What worked for checking Hammerspoon APIs live: temporarily
append a `hs.timer.doAfter(2, …)` block to `init.lua` that writes its results to a file,
open Hammerspoon, read the file, then restore `init.lua` from the repo and quit it.

State machine has a watchdog. `recording` stuck 150s (a lost key-up or a forgotten toggle)
stops sox and puts the transcript on the CLIPBOARD, never pasting, because focus may be anywhere
by then. `working` stuck 75s abandons the turn (`wf.turn` bumps, so the late callback drops
its result) and hands back the user's words, or in command mode their own clipboard. If
hold-to-talk feels dead, check `wf.diag()` for the eventtap first.

## Commit conventions

- Terse, imperative subject describing the *behavior* change (see `git log` for the house style).
- **Never** commit a key, a `*.pref`, `eval/history.csv`, or any real name / user path.
- Update `README.md` when the mode set, permissions, or install steps change.

## Where the rest of the context lives

- User-facing: `README.md`. Go-to-market, pricing, and roadmap are deliberately NOT in
  this repo — they live in the private vault (`Efforts/Active/Senti/`). If you find
  yourself writing strategy here, that's the signal it belongs there instead.
- Claude memory: `whisper-flow-local-dictation-2026-07-03.md` (has the full audited state).
