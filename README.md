<p align="center">
  <img src="assets/logo-wave.png" width="150" alt="Senti logo">
</p>

<h1 align="center">Senti 🎤</h1>

**Free, 100% local speech-to-text for macOS** — a Wispr Flow alternative. Hold a
key, speak, and your words are typed into whatever app you're in. Audio never
leaves your Mac.

*Senti* — Italian for "listen / hear."

---

## Why

- **Private & free** — transcription runs on a local [whisper.cpp](https://github.com/ggerganov/whisper.cpp) server bound to `127.0.0.1`. Your voice never touches the network.
- **Fast** — the model stays warm in Apple-Silicon Metal memory; dictation lands in ~0.2–0.8s.
- **CPU-light** — near-zero idle CPU; the optional AI transforms offload to the cloud, so no local LLM burns your battery.
- **Cheap** — the AI modes run on `gpt-6-luna` ($0.10 / $0.50 per million tokens): a prompt rewrite is ~2s and a fraction of a cent.

## Modes

| Gesture | Mode | What it does |
|---|---|---|
| Hold **right ⌥** | **Dictate** | Types exactly what you say (verbatim). 100% local — never leaves the Mac. |
| Hold **right ⌘** | **Prompt** | Turns a rough spoken idea into an optimized LLM prompt. Reads a **screenshot for context** (what app/task you're in); falls back to text-only if Screen Recording isn't granted. |
| Hold **Fn (🌐)** | **Command** | Transforms your **selected text** by voice ("make this a bullet list", "fix grammar"). No selection → generates at the cursor. |
| **⌃⌥V** | **Context** | Screenshots your screen + your instruction → drafts a context-aware reply / edit / answer at the cursor. |
| `⌃⌥D` / `⌃⌥P` / `⌃⌥C` | — | Hands-free toggle versions of dictate / prompt / command. |

The floating pill shows **Listening → Thinking → done**. The menu-bar 🎤 controls
Speed (Fast/Accurate), permissions, and engine restart.

> **Privacy note:** verbatim dictation (right ⌥) is 100% local — audio is transcribed by a
> whisper.cpp server bound to `127.0.0.1` and never leaves the Mac. The AI modes
> (prompt/command/context) send **text** — and, when screen context is on, a
> downscaled **screenshot** — to the configured API. Those modes are opt-in, fire only
> when you press their key, and never run in the background.
>
> Senti never puts your speech on a command line: text moves between components via the
> environment, because `ps` is readable by every process on the machine. The self-test
> asserts this with a canary on every run.
>
> **Security posture** (audited): the `hs` command-line bridge, which would let any process
> on your Mac run code inside Senti, is **off by default**. Untrusted text — including a
> web page's browser-tab title — is fed to the AI as fenced *data it must never obey*, and
> the AI's output is only ever *typed*, never run. Your notes leave the Mac only as a capped,
> section-limited digest, logged each time. The log stores no transcripts, and audio and
> screenshots are wiped the moment each turn ends.

## Features

- **Smart Formatting** — strips filler words (um/uh), re-capitalizes, and applies a **custom dictionary** (`replacements.txt`, e.g. "cloud md" → `CLAUDE.md`).
- **Fast / Accurate model toggle** — base.en (~0.3s) vs large-v3-turbo (best proper-noun accuracy).
- **Reusable operating-prompt layer** (`prompts/operating.md`) — a behavior layer prepended to every AI mode so output stays high-signal and concise.
- **Second brain (Obsidian)** — if you keep an Obsidian vault, prompt mode reads a small digest of *your own note* for the project you're in, so prompts are grounded in what the project actually is. Scoped hard: only allowlisted folders (never `People/`), capped size, every injection logged, `WF_BRAIN=0` to kill. A cheap background call (~$0.001) keeps a compressed digest fresh per project, refreshed lazily only when you actually work on it. Add a `## Senti` section to any note to control exactly what Senti may see.
- **Model-aware prompting** — Senti notices which app you're in and writes the prompt *for the model you're about to paste into*. Ask for the same thing in Claude and in ChatGPT and you get two different prompts: the Claude one uses XML tags and states scope explicitly; the ChatGPT one stays lean and tells the model to assume-and-proceed rather than ask. The guidance lives in `prompts/models/*.md` (distilled from ~90 sources across OpenAI, Anthropic, Google, open-weight models, and prompting research) — edit those files and the behavior changes. Detection reads the frontmost app name locally, so it costs no extra API call.
- **Per-window session memory** — if you run several terminals at once, Senti keeps them apart. Session identity is the *window*, not the app, so four Claude Code terminals are four separate contexts. It reads the project and current task straight off the window title, so saying **"now do the same for the download one"** resolves correctly — and differently — in each terminal. No screenshots, no extra API call, nothing leaves the Mac.
- **Cache hygiene** — `~/.cache/senti` holds the raw audio of what you just said and a full-resolution picture of your screen. Both are deleted the moment a turn finishes, with a 60-second backstop and a sweep at launch. Session notes are mode 600 and expire after 24h.
- **Self-test** — `bash ~/.config/senti/senti-selftest.sh` runs its full check suite end to end: engine, config schema, key permissions, icon build, live API latency, session isolation, and a canary proving your dictated text never reaches the process table.
- **Offline eval harness** — `senti-eval.sh` scores prompt-mode output across fixed cases so prompt-strategy changes are *measurable* (A/B via env, history in `eval/history.csv`).

## Install

```bash
git clone <this-repo> ~/code/senti && cd ~/code/senti && ./install.sh
```

Requirements (Homebrew / Xcode CLT):

```bash
brew install whisper-cpp sox resvg   # resvg renders the app icon
brew install --cask hammerspoon
# a model, e.g.:
mkdir -p ~/.local/share/whisper-models
# Accurate (the default — best with proper nouns and code identifiers, ~0.8s):
curl -L -o ~/.local/share/whisper-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
# Optional: Fast (~0.3s, English-only) — menu bar → Speed → Fast
curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Grant **Hammerspoon** the macOS permissions it needs:
- **Accessibility** (to type) — usually prompted on first use.
- **Microphone** — menu-bar 🎤 → *Grant / test microphone* → Allow.
- **Screen Recording** *(only for context / screen-aware prompt modes)* — menu-bar 🎤 → *Grant screen recording*, then relaunch Hammerspoon.

For the AI modes, one key (optional — verbatim dictation needs nothing):

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

- `senti-serve.sh` — warm whisper.cpp server (launchd `io.senti.server`).
- `senti-dictate.sh` — record / stop / transcribe / clean / silence-gate / dictionary.
- `senti-ai.sh` — the single shared OpenAI text call, prepends the operating layer.
- `senti-target.sh` / `senti-session.sh` / `senti-brain.sh` — model guidance, per-window memory, vault bridge.
- `senti-selftest.sh` — the full end-to-end check suite.
- `senti-prompt.sh` — prompt mode (one call; craft + vault + session + target-model guidance).
- `senti-command.sh` — transform selected text.
- `senti-vision.sh` — OpenAI vision for context + screen-aware prompt.
- `senti-judge.sh` / `senti-eval.sh` — prompt-quality judge + offline eval harness.
- `senti-model.sh` — Fast/Accurate model switch.
- `senti-mic-auth.swift` — triggers the macOS mic-permission prompt.
- `senti.lua` — Hammerspoon hotkeys, HUD, menu bar, state machine + watchdog.

## Config

Everything is tunable in `config.sh` — models, language, silence threshold, vision
model, vault bridge (`WF_BRAIN`), operating layer (`WF_OPERATING_LAYER`).
Edit `replacements.txt` for vocabulary fixes and `eval/cases.txt` for eval cases.

---

**Contributing / hacking on this?** See [`CLAUDE.md`](CLAUDE.md) — the repo→live-system
map, conventions, and the macOS gotchas that will otherwise cost you an afternoon.

Built locally with Claude. Audio stays on your machine.
