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
- **CPU-light** — near-zero idle CPU; AI transforms offload to the cloud, so no local LLM burns your battery.

## Modes

| Gesture | Mode | What it does |
|---|---|---|
| Hold **right ⌥** | Dictate | Types exactly what you say (verbatim) |
| Hold **right ⌘** | Prompt | Rewrites rough speech into an expert LLM prompt |
| Hold **Fn (🌐)** | Command | Transforms your *selected text* by voice ("make this a bullet list") |
| `⌃⌥D` / `⌃⌥P` / `⌃⌥C` | — | Hands-free toggle versions of each |

The floating pill shows **Listening → Thinking → done**. Menu-bar 🎤 controls speed,
mic permission, and engine restart.

## Features

- **Smart Formatting** — strips filler words (um/uh) and re-capitalizes.
- **Custom dictionary** (`replacements.txt`) — fixes mistranscriptions (e.g. "cloud md" → `CLAUDE.md`).
- **Fast / Accurate toggle** — base.en (~0.3s) vs large-v3-turbo (best proper-noun accuracy).
- **AI modes via DeepSeek** — cheap, ~1.3s; falls back to the local `claude` CLI.

## Install

```bash
git clone <this-repo> ~/code/senti && cd ~/code/senti && ./install.sh
```

Requirements (installed via Homebrew / Xcode CLT):

```bash
brew install whisper-cpp sox
brew install --cask hammerspoon
# download a model, e.g.:
curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Then grant **Hammerspoon** two macOS permissions: **Accessibility** (to type) and
**Microphone** (menu-bar 🎤 → Grant / test microphone → Allow).

For AI modes (prompt/command), drop an API key:

```bash
echo "sk-..." > ~/.config/senti/deepseek-key   # DeepSeek (recommended)
```

## Architecture

```
hold key ─▶ Hammerspoon (init.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command modes ─▶ senti-ai.sh ─▶ DeepSeek API (or claude CLI)
```

- `senti-serve.sh` — warm whisper.cpp server (launchd `com.leo.senti`).
- `senti-dictate.sh` — record / stop / transcribe / clean / silence-gate.
- `senti-prompt.sh`, `senti-command.sh`, `senti-ai.sh` — AI modes.
- `senti-model.sh` — Fast/Accurate model switch.
- `senti-mic-auth.swift` — triggers the macOS mic-permission prompt.
- `senti.lua` — Hammerspoon hotkeys, HUD, menu bar.

## Config

Everything is tunable in `config.sh` (models, language, silence threshold, sounds).
Edit `replacements.txt` to add your own vocabulary fixes.

---

Built locally with Claude. Audio stays on your machine.
