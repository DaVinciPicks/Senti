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

## Modes

| Gesture | Mode | What it does |
|---|---|---|
| Hold **right ⌥** | **Dictate** | Types exactly what you say (verbatim). 100% local — never leaves the Mac. |
| Hold **right ⌘** | **Prompt** | Turns a rough spoken idea into an optimized LLM prompt. Reads a **screenshot for context** (what app/task you're in); falls back to text-only if Screen Recording isn't granted. |
| Hold **Fn (🌐)** | **Command** | Transforms your **selected text** by voice ("make this a bullet list", "fix grammar"). No selection → generates at the cursor. |
| **⌃⌥V** | **Context** | Screenshots your screen + your instruction → drafts a context-aware reply / edit / answer at the cursor. |
| `⌃⌥D` / `⌃⌥P` / `⌃⌥C` | — | Hands-free toggle versions of dictate / prompt / command. |

The floating pill shows **Listening → Thinking → done**. The menu-bar 🎤 controls
Speed (Fast/Accurate), Prompt quality (Fast/Best), permissions, and engine restart.

> **Privacy note:** verbatim dictation (right ⌥) is 100% local. The AI modes
> (prompt/command/context) send **text** — and, when screen context is on, a
> downscaled **screenshot** — to the configured API. Those modes are opt-in.

## Features

- **Smart Formatting** — strips filler words (um/uh), re-capitalizes, and applies a **custom dictionary** (`replacements.txt`, e.g. "cloud md" → `CLAUDE.md`).
- **Fast / Accurate model toggle** — base.en (~0.3s) vs large-v3-turbo (best proper-noun accuracy).
- **Reusable operating-prompt layer** (`prompts/operating.md`) — a behavior layer prepended to every AI mode so output stays high-signal and concise.
- **Few-shot prompt exemplars + Best mode** — prompt mode learns from bootstrapped examples; **Best mode** generates several candidate prompts and a judge picks/merges the strongest (menu → *Prompt quality → Best*).
- **Offline eval harness** — `senti-eval.sh` scores prompt-mode output across fixed cases so prompt-strategy changes are *measurable* (A/B via env, history in `eval/history.csv`).

## Install

```bash
git clone <this-repo> ~/code/senti && cd ~/code/senti && ./install.sh
```

Requirements (Homebrew / Xcode CLT):

```bash
brew install whisper-cpp sox
brew install --cask hammerspoon
# a model, e.g.:
curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Grant **Hammerspoon** the macOS permissions it needs:
- **Accessibility** (to type) — usually prompted on first use.
- **Microphone** — menu-bar 🎤 → *Grant / test microphone* → Allow.
- **Screen Recording** *(only for context / screen-aware prompt modes)* — menu-bar 🎤 → *Grant screen recording*, then relaunch Hammerspoon.

For the AI modes, drop keys (both optional; prompt/command work with DeepSeek, context/vision need OpenAI):

```bash
echo "sk-..." > ~/.config/senti/deepseek-key   # text modes (cheap)
echo "sk-..." > ~/.config/senti/openai-key      # vision (context + screen-aware prompt)
```

## Architecture

```
hold key ─▶ Hammerspoon (senti.lua) ─▶ sox records mic ─▶ SIGINT finalizes WAV
                                                              │
        types via ⌘V ◀─ clean/format/dictionary ◀─ whisper-server (127.0.0.1, warm) ◀┘
                                          │
   prompt/command ─▶ senti-ai.sh   ─▶ DeepSeek (→ claude fallback)   [+ operating layer]
   context/prompt+screen ─▶ senti-vision.sh ─▶ gpt-4o-mini (reads a downscaled screenshot)
```

- `senti-serve.sh` — warm whisper.cpp server (launchd `com.leo.senti`).
- `senti-dictate.sh` — record / stop / transcribe / clean / silence-gate / dictionary.
- `senti-ai.sh` — shared text AI call (DeepSeek → claude), prepends the operating layer.
- `senti-prompt.sh` — prompt mode (Fast few-shot / Best candidates→judge).
- `senti-command.sh` — transform selected text.
- `senti-vision.sh` — OpenAI vision for context + screen-aware prompt.
- `senti-judge.sh` / `senti-eval.sh` — prompt-quality judge + offline eval harness.
- `senti-model.sh` — Fast/Accurate model switch.
- `senti-mic-auth.swift` — triggers the macOS mic-permission prompt.
- `senti.lua` — Hammerspoon hotkeys, HUD, menu bar, state machine + watchdog.

## Config

Everything is tunable in `config.sh` — models, language, silence threshold, vision
model, prompt quality (`WF_PROMPT_BEST`), operating layer (`WF_OPERATING_LAYER`).
Edit `replacements.txt` for vocabulary fixes and `eval/cases.txt` for eval cases.

---

**Contributing / hacking on this?** See [`CLAUDE.md`](CLAUDE.md) — the repo→live-system
map, conventions, and the macOS gotchas that will otherwise cost you an afternoon.

Built locally with Claude. Audio stays on your machine.
