<p align="center">
  <img src="assets/senti-icon.png" width="160" alt="Senti logo: a white S with a waveform on a blue tile">
</p>

<h1 align="center">Senti</h1>

<p align="center">Free, local speech-to-text for macOS. Hold a key, speak, and your words are typed
into whatever app you're in. Audio never leaves your Mac.</p>

*Senti* is Italian for "listen."

I built it because I wanted to speak naturally, keep audio processing local, improve my prompts,
and work inside the applications I already use. I also wanted to avoid another subscription.

## Why

Transcription runs on a local [whisper.cpp](https://github.com/ggerganov/whisper.cpp) server bound to
`127.0.0.1`, so your voice never touches the network. The model stays loaded in memory, which is why
dictation comes back in about 0.2 to 0.8 seconds. While you aren't speaking, Senti uses almost no
CPU.

Dictation is free. The optional AI modes call `gpt-6-luna` ($0.10 / $0.50 per million tokens) with
your own key. A prompt rewrite takes about 2 seconds and costs a fraction of a cent.

## Modes

| Gesture | Mode | What it does |
|---|---|---|
| Hold **right ⌥** | **Dictate** | Types exactly what you say. Fully local. |
| Hold **right ⌘** | **Prompt** | Turns a rough spoken idea into a prompt written for the model you're about to paste into. Reads a screenshot for context, and falls back to text only if Screen Recording isn't granted. |
| Hold **Fn** | **Command** | Transforms your selected text by voice ("make this a bullet list", "fix grammar"). With no selection, it writes at the cursor. |
| **⌃⌥V** | **Context** | Takes a screenshot plus your instruction, then drafts a reply, edit or answer at the cursor. |
| `⌃⌥D` / `⌃⌥P` / `⌃⌥C` | Toggles | Hands-free versions of Dictate, Prompt and Command. |

A small pill at the bottom of the screen shows a live waveform while you speak, then disappears.
The AI modes add their name to it. The menu-bar icon controls speed (Fast or Accurate),
permissions and engine restart.

### Privacy

Dictation is fully local. Audio is transcribed by a whisper.cpp server bound to `127.0.0.1` and
never leaves the Mac.

The AI modes (Prompt, Command, Context) send text to the configured API. When screen context is
on, they also send a downscaled screenshot. They run only when you press their key, never in the
background.

Senti never puts your speech on a command line. Text moves between components through the
environment, because `ps` is readable by every process on the machine. The self-test checks this
with a canary on every run.

### Security

- The `hs` command-line bridge, which would let any process on your Mac run code inside Senti, is off by default.
- Untrusted text, including a browser tab's title, is passed to the AI as fenced data it must never obey.
- The AI's output is only ever typed, never run.
- Your notes leave the Mac only as a capped, section-limited digest, and each one is logged.
- The log stores no transcripts. Audio and screenshots are deleted the moment each turn ends.

## Features

### Formatting

Senti strips filler words (um, uh), fixes capitalization, and applies your own dictionary from
`replacements.txt`. Mine turns "cloud md" into `CLAUDE.md`. You can switch between two speech
models from the menu bar: base.en answers in about 0.3 seconds, and large-v3-turbo is slower but
better with proper nouns.

### Prompts written for the model you're using

Senti notices which app is in front and writes the prompt for the model you're about to paste into.
Ask for the same thing in Claude and in ChatGPT and you get two different prompts. The Claude one
uses XML tags and states scope explicitly. The ChatGPT one is shorter and tells the model to make
its own assumptions and keep going. The guidance lives in `prompts/models/*.md`, which I distilled
from about 90 sources across OpenAI, Anthropic, Google, open-weight models and prompting research.
Edit those files and the behavior changes. Detection reads the frontmost app's name on your Mac, so
it costs no extra API call.

Every AI mode also gets `prompts/operating.md` prepended, a short set of rules that keeps the
output brief.

### Memory per window

If you run several terminals at once, Senti keeps them apart. A session is a window, so four Claude
Code terminals are four separate contexts. It reads the project and the current task from the window
title. Say "now do the same for the download one" in two terminals and each resolves it against its
own history. This uses no screenshots and no extra API call.

### Your notes, if you want them

If you keep an Obsidian vault, Prompt mode can read a short digest of your note for the project
you're in, so the prompt reflects what the project is. It only reads folders you allow (never
`People/`), the digest has a size cap, and every use is logged. A background call of about $0.001
refreshes the digest for a project when you work on it. Add a `## Senti` section to a note to
control exactly what Senti sees, or set `WF_BRAIN=0` to turn the feature off.

### Housekeeping

`~/.cache/senti` holds the audio of what you just said and a full-resolution picture of your screen.
Both are deleted when the turn finishes, with a 60-second backstop and a sweep at launch. Session
notes are readable only by you and expire after 24 hours.

`bash ~/.config/senti/senti-selftest.sh` checks the whole install: the speech engine, the config
version, key permissions, the icon build, live API latency, session isolation, and a canary that
proves your dictated text never appears in the process table.

`senti-eval.sh` scores Prompt mode against a fixed set of cases, so a change to the prompt strategy
can be measured. Results go to `eval/history.csv`.

## Install

```bash
git clone https://github.com/DaVinciPicks/Senti.git ~/code/senti && cd ~/code/senti && ./install.sh
```

Requirements (Homebrew / Xcode CLT):

```bash
brew install whisper-cpp sox resvg   # resvg renders the app icon
brew install --cask hammerspoon
# a model, e.g.:
mkdir -p ~/.local/share/whisper-models
# Accurate (the default; best with proper nouns and code identifiers, ~0.8s):
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
# Optional: Fast (~0.3s, English-only). Menu bar → Speed → Fast
curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Grant **Hammerspoon** the macOS permissions it needs:
- **Accessibility** (to type): usually prompted on first use.
- **Microphone**: menu-bar icon → *Grant / test microphone* → Allow.
- **Screen Recording** (only for the Context and screen-aware Prompt modes): menu-bar icon → *Grant screen recording*, then relaunch Hammerspoon.

The AI modes (Prompt, Command, Context) need your own OpenAI API key. This is optional, and
dictation works without it:

```bash
echo "sk-..." > ~/.config/senti/openai-key && chmod 600 ~/.config/senti/openai-key
```

## Architecture

```
hold key ─▶ Hammerspoon (senti.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format/dictionary ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command ─▶ senti-ai.sh   ─▶ gpt-6-luna   [+ operating layer]
   context/prompt+screen ─▶ senti-vision.sh ─▶ gpt-6-luna (reads a downscaled screenshot)
   prompt mode also ─▶ senti-target.sh (which model you're pasting into)
                   ├─▶ senti-session.sh (this window's recent turns)
                   └─▶ senti-brain.sh  (your Obsidian note for this project)
```

- `senti-serve.sh`: warm whisper.cpp server (launchd `io.senti.server`).
- `senti-dictate.sh`: record / stop / transcribe / clean / silence-gate / dictionary.
- `senti-ai.sh`: the single shared OpenAI text call, prepends the operating layer.
- `senti-target.sh` / `senti-session.sh` / `senti-brain.sh`: model guidance, per-window memory, vault bridge.
- `senti-selftest.sh`: the full end-to-end check suite.
- `senti-prompt.sh`: prompt mode (one call; craft + vault + session + target-model guidance).
- `senti-command.sh`: transform selected text.
- `senti-vision.sh`: OpenAI vision for context + screen-aware prompt.
- `senti-judge.sh` / `senti-eval.sh`: prompt-quality judge + offline eval harness.
- `senti-model.sh`: Fast/Accurate model switch.
- `senti-mic-auth.swift`: triggers the macOS mic-permission prompt.
- `senti.lua`: Hammerspoon hotkeys, HUD, menu bar, state machine + watchdog.

## Config

Everything is tunable in `config.sh`: models, language, silence threshold, vision
model, vault bridge (`WF_BRAIN`) and operating layer (`WF_OPERATING_LAYER`).
Edit `replacements.txt` for vocabulary fixes and `eval/cases.txt` for eval cases.

Working on the code? [`CLAUDE.md`](CLAUDE.md) maps the repo to the installed system and lists the
macOS gotchas that will otherwise cost you an afternoon.

MIT licensed. See [`LICENSE`](LICENSE).
