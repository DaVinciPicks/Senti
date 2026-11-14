# Changelog

All notable changes to Senti. Dates are in US Eastern time.

## [Unreleased] 1.1

### Added

- **Anthropic and OpenRouter** as AI providers next to OpenAI, behind one adapter in `senti-ai.sh`,
  each with its own key. Both are tested offline (request shapes, a refused key maps to the right
  error); a live check with real keys is still pending.
- `ai-models.json`: every provider and model Senti knows, with prices and the efforts each model
  accepts.
- `senti-key.sh`, the key helper: `set` (hidden prompt or standard input, never argv), `test`,
  `clear`, `status`, `use` and `migrate`. Keys are stored in the macOS Keychain. An older plaintext
  key file is moved into the Keychain and deleted only after the copy reads back byte for byte.
- **AI provider and key…** panel in the menu bar. It opens once on the first run when no key exists,
  saves and tests a key, links to the provider's key page, and removes a key. A plain dialog is the
  fallback.
- Model picker in the menu bar and the panel.
- Menu toggle **Use a screenshot in Prompt**.
- Menu item **What the last AI request sent**, backed by `~/.cache/senti/last-request.json` (names
  and counts only, no text).
- Esc cancels a recording or an AI turn while the pill is showing.
- `uninstall.sh`, which asks before each step and restores your previous `init.lua` when the current
  one is Senti's. Your current `init.lua` is saved as `init.lua.senti-<date>.bak` before your old one is restored, so edits you made inside Senti's file are kept in that copy.
- An optional key step in `install.sh` (terminal only, never with `--yes`).
- `senti-selftest.sh --ci`: an offline mode for CI, plus a transcription round trip and key canaries.
- An eval harness that can prove a change, with a base-vs-base row.
- Prompt guidance for the current Claude models, with a fallback to the nearest older model.
- `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md`, this changelog, a CI workflow, issue templates and
  a pull request template.

### Changed

- New logo: the geometric S, white on a blue badge.
- The recording pill draws the real microphone level and moves continuously. Toasts fade, stay long
  enough to read and hold while hovered.
- AI errors now have typed exit codes (10 to 19), and the notices name the provider and the cause.
- Faster dictation path: key-down to recorder start went from 0.127 s to 0.018 s, and the short-clip
  speedup now applies up to 14 s instead of 10 s, which took an 11.7 s clip from 1.04 s to 0.59 s
  (recorded clips on an M3 Pro, 13 Nov 2026).
- `config.sh` is now schema v9. Upgrading from 1.0 saves your old file as `config.sh.v8.bak` and
  installs the new one; copy your personal settings back from that file.
- The notes digest is no longer sent in the background to be shortened. That step is deleted, and the
  log says what each request sent.
- System prompts moved off the command line in every wrapper, and wrappers keep the cause of an AI
  error instead of replacing it with a generic one.
- Notices, menus and installer messages no longer use em dashes.
- README: the key step no longer writes the key with `echo`, which left it in shell history.

### Fixed

- A reply cut off at the token limit exits 17 instead of pasting half an answer.
- A failed Keychain write no longer leaves an older key in place that would keep being used; `set`
  exits 1 and says nothing was saved.
- `senti-key.sh set` rejects a key with whitespace inside it, and says "no key given" when the key
  field is empty instead of waiting on standard input.
- A test keychain path with whitespace, quotes or a backslash is refused, so a test can never reach
  your login keychain.
- `uninstall.sh` keeps an `init.lua` that is not Senti's, restores a symlinked `init.lua` through the
  link, stops when HOME is empty, and no longer claims Keychain items are gone when it could not
  clear them.
- The project name from the window title no longer appears in a file listing's arguments when
  Senti looks for the Claude Code session file; the lookup is a bash glob loop.
- The notes bridge checks each note and folder by its real path, so a symlinked folder or note that
  points outside the folders in `WF_BRAIN_DIRS` is ignored instead of read.
- Reading an empty `model.pref` no longer stops the speech server from starting.
- Esc during Command sends nothing, stops the request in flight, and restores an empty clipboard to
  empty.
- An out-of-date "no key" status never blocks an AI turn on its own.

## [1.0.0] 2026-11-11

First public release under the MIT license.
