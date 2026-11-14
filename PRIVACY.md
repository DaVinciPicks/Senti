# Privacy

Senti has no server, no account and no analytics. Dictation runs on your Mac and sends nothing.
The 3 AI modes (Prompt, Command and Context) send text, and sometimes a screenshot, to the one AI
provider you chose, and only when you use them.

This page lists exactly what leaves your Mac, what Senti reads, what it stores and for how long. It
describes the code in this repository as of 13 November 2026.

## What leaves your Mac

| Mode | What is sent | Where |
|---|---|---|
| **Dictate** (hold right ⌥) | Nothing. The audio goes to the speech server on `127.0.0.1`, on your Mac. | nowhere |
| **Prompt** (hold right ⌘) | Your words. Senti's own instructions (from `prompts/`), including guidance for the model you are about to paste into, which names that model. A downscaled screenshot when **Use a screenshot in Prompt** is on (the default) and Hammerspoon has Screen Recording permission. | your provider |
| **Prompt, heavy turn** | Everything above, plus a fenced block of context: the project and task from the window title, this window's recent Senti turns, and your notes digest if notes are on. See the next section. | your provider |
| **Command** (hold Fn) | Your words and the text you selected, if any. No screenshot. | your provider |
| **Context** (⌃⌥V) | Your words and a downscaled screenshot. Context always takes one, because reading the screen is what it is for. | your provider |

"Your provider" is the one host of the provider you picked: `api.openai.com`, `api.anthropic.com`
or `openrouter.ai`. Your API key goes only to that host.

The screenshot is of your main display, shrunk with `sips` so its long edge is 1536 pixels
(`WF_SHOT_PX` in `config.sh`) and saved as JPEG. If `sips` fails, the original PNG is sent instead.

The self-test and the eval scripts also call your provider, but only when you run them. The
self-test's live check sends a screenshot of your main display.

### Heavy turns: when history and notes are sent

A Prompt turn is "heavy" only when what you say opens with **"think hard"** or **"today let's work
on"** (also "think harder", "let's think hard" and "today let us work on"). Every other Prompt turn is
light and sends none of the following.

On a heavy turn Senti adds:

- **The window title's project and task**, for example the project and current task shown in a
  terminal's title.
- **Session memory for this window**: your last Prompt, Command and Context turns in the same window,
  up to 12 of them, 200 characters each, from the last 24 hours. Dictation turns are never stored, so
  they can never be sent this way.
- **Your notes digest**, only if you turned notes on with `WF_BRAIN=1` and listed folders in
  `WF_BRAIN_DIRS`. Senti picks the note for the current project and sends its `## Senti` section. A
  note without one sends its `## For future Claude` section, or else its first 10 lines. The digest is
  capped at 700 characters (`WF_BRAIN_MAX`). Add a `## Senti` section to a note to decide exactly what
  can leave. To see what would be sent, without sending anything, run
  `bash ~/.config/senti/senti-brain.sh --preview <project>`.

Senti prepares this block locally when you press right ⌘, before you speak. Nothing is sent until a
heavy turn's request goes out. Each part that joins a request is written to the log as a count, for
example `sent: vault 'Note.md' 412 chars`.

### OpenRouter

Every OpenRouter request carries `"provider": {"data_collection": "deny"}`, which tells OpenRouter to
route only to model hosts that do not store or train on the data. If no host qualifies, the request
fails instead of going elsewhere. Setting `WF_OPENROUTER_ZDR=1` in `config.sh` also asks for
zero-data-retention routing, which is stricter and can leave a model with no host.

### What your provider does with it

Each provider sets its own rules for API data:

- OpenAI: [Your data](https://developers.openai.com/api/docs/guides/your-data)
- Anthropic: [Privacy policy](https://www.anthropic.com/legal/privacy)
- OpenRouter: [Privacy policy](https://openrouter.ai/privacy) and
  [provider logging](https://openrouter.ai/docs/guides/privacy/provider-logging)

These links opened on 13 November 2026.

## What Senti reads on your Mac

Some of this is sent, as the tables above say. The rest never leaves the Mac.

- The name of the app in front and its window title. The title picks the model guidance and, on
  heavy turns only, supplies the project and task listed above.
- The last 120 KB of the newest Claude Code session file for the project in the title
  (`~/.claude/projects/...`), to learn which Claude model you are using. Only the model name can
  reach a prompt, inside the model guidance.
- The git branch of `~/code/<project>`, read from `.git/HEAD`, plus your `replacements.txt`. These
  become a short spelling hint for the local speech server and never leave the Mac.
- The text you select, in Command mode, which is sent as listed above.
- The notes folders you list, if notes are on.
- Your clipboard, held in memory during a paste or a Command turn so it can be put back. It is never sent or saved.

## What Senti stores, and for how long

| Where | What | How long |
|---|---|---|
| macOS Keychain, service `io.senti` | Your API key for each provider | Until you remove it (the key panel, `senti-key.sh clear <provider>`, or `uninstall.sh`) |
| `~/.config/senti/<provider>-key` | Your key, only when the Keychain was locked or unavailable. Mode 600, plain text | Until you remove it |
| `~/.config/senti/ai.pref`, `ui.pref` | Your provider, model and screenshot choices | Until you change them |
| `~/.cache/senti/capture.wav`, `screen.png`, `screen-small.jpg`, `selection.txt`, `ctx-*` | The audio, screenshot, selected text and prepared context of the current turn | Deleted at the end of each turn, when Senti starts, and every 60 seconds while it is idle |
| `~/.cache/senti/sessions/<window>.tsv` | Session memory: Prompt, Command and Context turns, 200 characters each, at most 12 per window. Mode 600 | Turns older than 24 hours are never recalled. Files are deleted 24 hours after their last turn, at launch and every 30 minutes while Senti runs |
| `~/.cache/senti/last-request.json` | Names and counts from the last AI request. Mode 600. No speech, prompt or answer text | Replaced by the next AI request |
| `~/Library/Logs/senti.log` | Events, character counts, note file names. Mode 600. Transcripts only if you set `WF_DEBUG=1` | Never rotated |
| `~/Library/Logs/senti-server.log` | The speech server's start-up lines and one line per request with the audio file name. A check of a real log on 13 November 2026 found no transcript text | Never rotated |

The folders `~/.config/senti` and `~/.cache/senti` are mode 700, so other macOS users on the same
Mac cannot open them. Programs running as you can.

Senti types by pasting. The pasted text is marked transient and concealed on the clipboard, which
clipboard managers that follow that convention skip. Universal Clipboard can still sync it to your
other Apple devices.

## See what the last request sent

The menu bar has **AI → What the last AI request sent**. It shows the contents of
`last-request.json`: when it ran, the mode, the provider and host, the model and effort, whether a
screenshot went along, and each part of the request by source (speech, selection, window title,
session, notes, model guidance) with its character count. It shows the note's file name and the
target model's name, never the text. Dictation never writes to it.

## Turning things off

- **Notes:** leave `WF_BRAIN` unset, or set `WF_BRAIN=0`, in `~/.config/senti/config.sh`.
- **Screenshots in Prompt:** turn off **AI → Use a screenshot in Prompt** in the menu bar. Context
  mode still takes one, since that is its job; don't use ⌃⌥V if you want none.
- **History and window title in Prompt:** don't open a turn with "think hard" or "today let's work
  on".
- **All AI modes:** remove your key in **AI provider and key…**, or run
  `bash ~/.config/senti/senti-key.sh clear <provider>`. Dictation keeps working without a key.

## The website

The site at usesenti.io has no analytics. On 13 November 2026 the live page and its CSS and JavaScript
files were read for addresses on other hosts: none is loaded. The only other-host addresses are plain
links and SVG namespace strings. The next site build was checked in a browser
the same day at 6 screen widths and made 0 requests to other hosts.

## Removing Senti and its data

Run `./uninstall.sh` from your copy of the repository. It asks before each step. It removes the
LaunchAgent, Senti.app, `~/.cache/senti` and the logs, and asks separately about `~/.config/senti`
with your Keychain items, and about the speech models. See the README's Uninstall section.

## Changes

- **13 November 2026 (1.1, unreleased):** Anthropic and OpenRouter added as providers. Keys moved to
  the macOS Keychain. The background step that sent a notes digest to the model to shorten it was
  deleted, so there is no background upload, and old digests it left in `~/.cache/senti/brain/` are
  deleted by the session sweep. Added the screenshot toggle for Prompt, `last-request.json` and the
  menu item that shows it.
