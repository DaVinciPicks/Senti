# Contributing to Senti

Thanks for helping. Senti is small, so a short read of this page and of [`CLAUDE.md`](CLAUDE.md)
(the map from repository files to the installed system, and the macOS gotchas) covers most of what
you need.

Security problems go through [`SECURITY.md`](SECURITY.md), not a public issue.

## How the code reaches your Mac

This repository is the source. `./install.sh` copies it into place:

| Repository | Installed to |
|---|---|
| `senti-*.sh`, `config.sh`, `ai-models.json`, `replacements.txt`, `prompts/`, `eval/` | `~/.config/senti/` |
| `senti.lua` | `~/.hammerspoon/init.lua` |
| `io.senti.server.plist` | `~/Library/LaunchAgents/` |
| `app/` | `~/Applications/Senti.app` |

Edit files here, then run `./install.sh` again. Don't edit the installed copies: the next install
overwrites the scripts and `init.lua`. `config.sh`, `replacements.txt`, `brain-map.txt` and
`eval/cases.txt` are installed only when missing, so your local tuning survives.

## Before you open a pull request

1. **Syntax:** `for f in senti-*.sh install.sh uninstall.sh app/*.sh; do /bin/bash -n "$f"; done`
2. **Offline self-test, from your checkout:** `bash senti-selftest.sh --ci`. It needs no
   Hammerspoon, no speech server, no key and no network, and runs in a throwaway HOME with a
   throwaway keychain. CI runs the same two steps on every pull request.
3. **Installed self-test, if you changed runtime behaviour:** `./install.sh`, then
   `bash ~/.config/senti/senti-selftest.sh`. With a key, its live checks call your AI provider (a
   fraction of a cent) and send a screenshot of your main display. Set `WF_SELFTEST_OFFLINE=1` to skip
   them.
4. If you changed Prompt mode, measure it: `bash ~/.config/senti/senti-eval.sh ab <before> <after>`
   runs the cases in `eval/cases.txt` for both variants and judges them pairwise, with a
   before-against-before row that shows the noise. It calls your AI provider.

## Rules the code depends on

- **The argv rule.** Speech, the system prompt, window titles and API keys travel in environment
  variables (`SENTI_IN`, `SENTI_SYS`, and so on), never on a command line, at every layer: Lua to
  script, script to script, script to Python. `ps` shows every process's arguments to every other
  process. When you add a check for this to the self-test, never pipe the canary into `grep`: grep's
  own arguments then contain it and `ps` catches the test itself. Snapshot `ps` into a variable and
  match with a shell `case`.
- **Keys go through `senti-key.sh` only.** It is the one place that stores, reads and tests keys.
  Lua never calls `security` itself.
- **New cache files must be swept.** Anything sensitive you write under `~/.cache/senti` needs a
  pattern in `wf.sweepSensitive` in `senti.lua`, or it outlives the turn.
- **The log holds no content.** `senti.log` is never rotated. Log counts and names, not speech,
  window titles or keys. Full text belongs behind `WF_DEBUG=1`.
- **macOS ships bash 3.2 and BSD tools.** An empty array under `set -u` throws; use
  `"${ARR[@]+"${ARR[@]}"}"`. `sed -i` and `\U` behave differently from GNU.
- **Paths may contain spaces.** Quote every path. Never hard-code a home folder; use `$HOME`, or
  `__HOME__` in the plist.

## Keep keys and personal details out

- Never paste an API key into an issue, a pull request, a commit or a log excerpt. If output shows
  part of a key, replace it, for example `sk-...abcd`. `senti-key.sh status` prints only the last 4
  characters, so it is safe to share.
- Never commit `*-key`, `*.pref`, `eval/history.csv`, a real name, an email address or a
  full path to a home folder (write `$HOME` or `~` instead). Run `git status` and read your diff before each commit.

## Writing style for docs and user-facing text

- Plain sentences. Digits for numbers.
- No em or en dashes. No hype words. No "it's not X, it's Y".
- Every claim traces to the code or to a dated check. A measured number carries its date and the
  machine it was measured on.
- Update `README.md` when the modes, permissions or install steps change, and `PRIVACY.md` when what
  leaves the Mac changes.

## Commits

A short imperative subject that says what changed in behaviour, for example
`uninstall keeps a non-Senti init.lua`. One logical change per commit.
