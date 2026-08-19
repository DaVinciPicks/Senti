---
family: google-open
display_name: Google Gemini & open-weight models
match: gemini|vertex|aistudio|ai studio|notebooklm|llama|mistral|qwen|deepseek|gemma|ollama|lm studio
frontier: gemini-3.1-pro-preview
daily: gemini-3.6-flash
updated: 2026-08-09
---

## Prompting rules

1. **[Gemini]** Structure every prompt with one consistent delimiter convention — XML tags (`<role>`, `<context>`, `<task>`, `<constraints>`) or Markdown headers — and never mix the two in the same prompt. Gemini 3 is trained on this structure and is markedly less tolerant of unstructured prose than Gemini 2.5 was.
2. **[Gemini]** For long-context prompts, put ALL reference material (documents, code, transcripts) first, then the specific question or instruction LAST, bridged with an explicit transition like "Based on the information above...". Google's own docs state this ordering directly; leading with the question and appending documents afterward measurably underperforms it.
3. **[Gemini]** Don't expect chattiness by default — Gemini 3 "favors directness over persuasion and logic over verbosity" and gives terse, direct answers unless you explicitly ask for a conversational or detailed tone.
4. **[Gemini]** Skip hand-written chain-of-thought scaffolding for routine calls. Gemini 2.5 and 3 models generate internal "thinking" automatically; add "think very hard before answering" only for genuinely hard problems, since it burns extra thinking tokens.
5. **[Gemini]** Set the thinking-control param that matches the model generation and don't carry it across generations: Gemini 3.x uses `thinkingLevel` (`low`/`high`), Gemini 2.5.x uses `thinkingBudget` (a token count, or `-1` for dynamic). They are not interchangeable — sending the wrong one either 400s or silently no-ops.
6. **[Gemini]** For a single image + text, place the text prompt BEFORE the image in the input array (confirmed in Google's own image-understanding docs) — this is the opposite of the "image first" convention common elsewhere. For multiple images, list them in order and reference that order explicitly in the text.
7. **[Gemini]** Add an explicit current-date clause to the system instruction (e.g. "Remember it is 2026 this year") plus a knowledge-cutoff clause — Gemini 3 Flash needs this stated, not inferred, to reason correctly about recency and to formulate correct tool/search queries.
8. **[Open-weight]** Never approximate a model's chat template. Control tokens are family-specific and non-interchangeable: Gemma uses `<start_of_turn>user ... <end_of_turn>`, Llama has no special pre-assistant token, Mistral wraps instructions in `[INST]...[/INST]`, Qwen/DeepSeek use ChatML-style `<|im_start|>`/`<|im_end|>`. A close-but-wrong template degrades instruction-following silently — no error, just worse output.
9. **[Open-weight]** Check system-role support per family before assuming it exists. Gemma 3 and Gemma 4 both reject a system role entirely — fold system-level instructions into the start of the first user turn. Llama, Mistral, Qwen, and DeepSeek all support a real system role.
10. **[Open-weight, reasoning variants]** Don't default to a generic "You are a helpful assistant" system prompt on a reasoning/thinking-mode model. DeepSeek's own team found this exact line measurably *hurts* DeepSeek-V3.2/V4 thinking-mode performance; leave the system prompt empty or task-specific for reasoning-mode calls instead of reusing a chat-mode persona line.
11. **[Open-weight, Qwen]** Toggle Qwen3/3.5/3.6 reasoning explicitly: `enable_thinking` (true/false) is the hard switch at request time; `/think` and `/no_think` inline in the prompt is the soft switch that persists turn-to-turn until overridden. Don't assume a default — hybrid models can silently burn a full thinking pass on a simple turn if you never disable it.
12. **[Open-weight, quantization]** Below Q4 GGUF quantization (Q2/Q3), expect degraded instruction-following specifically on agentic/structured tasks — models start dropping parts of multi-step system prompts and malforming JSON. If a local model ignores format instructions it previously followed, check the quant level before rewriting the prompt.
13. **[Cross-vendor]** Shrink the prompt itself when moving from a frontier model to a small (≤30B) local model: one task per call instead of a multi-part composite, concrete examples of the specific failure modes you've actually seen (not generic examples), and a simpler, tighter output schema. Prompts tuned against a frontier model's tolerances reliably regress on small models — do an explicit small-model pass, don't just reuse the frontier prompt.
14. **[Cross-vendor]** Don't chain multi-step reasoning ("first do X, then verify, then reformat") into one call to a small non-reasoning open-weight model. Split it into separate calls/turns — small models lose track of multi-step instructions in a single pass that a frontier or dedicated reasoning model holds fine.

## Controls

| Param | Valid values | Use when |
|---|---|---|
| `thinkingLevel` (Gemini 3.x) | `low`, `high` | Reasoning depth control on Gemini 3-series models only — do not send to Gemini 2.5.x |
| `thinkingBudget` (Gemini 2.5.x) | token count (e.g. `128`–`32768`), or `-1` for dynamic | Reasoning depth on Gemini 2.5.x; some models (2.5 Pro) reject `0` and require a real budget or `-1` |
| `systemInstruction` | free text / structured XML block | Persistent role, format, tone, and time/knowledge-cutoff context — Gemini's equivalent of a system message |
| `media_resolution` (Gemini 3.x) | resolution tier | Raise for fine text/small-detail reading in images; costs more tokens per image (258 tokens per 384px tile at baseline) |
| `enable_thinking` (Qwen3.x) | `true` / `false` | Hard switch for hybrid Qwen reasoning mode at request time |
| `/think`, `/no_think` (Qwen3.x, inline) | literal string in prompt | Soft, per-turn override of thinking mode inside a multi-turn conversation |
| DeepSeek model id | `deepseek-v4-flash`, `deepseek-v4-pro` | Current valid IDs as of Aug 2026. `deepseek-chat` / `deepseek-reasoner` are retired (hard cutoff 2026-07-24) — see anti-patterns |
| GGUF quant level | `Q4_K_M` or higher for instruction-heavy/agentic use; `Q2_K`/`Q3_K` only when memory-constrained and format fidelity doesn't matter | Trade instruction-following reliability for footprint — never default to the smallest quant for tool-calling or structured-output tasks |

## Anti-patterns

- **Calling `deepseek-chat` or `deepseek-reasoner`** — both retired 2026-07-24 with a hard cutoff (no fallback, no grace period); calls now error outright rather than silently routing anywhere. Sanele's `sanele-ai.sh` currently targets `deepseek-chat` — verify live before relying on it, and migrate to `deepseek-v4-flash` (non-thinking, was `deepseek-chat`) or `deepseek-v4-pro` (thinking-first, was `deepseek-reasoner`-class).
- **Generic "helpful assistant" system prompt on a reasoning-mode call** — confirmed to measurably hurt DeepSeek V3.2/V4 thinking-mode output; also wastes tokens by inviting chattier non-answer preamble on Qwen3 thinking mode.
- **Mixing XML and Markdown delimiters in one Gemini 3 prompt** — pick one convention per prompt; mixing them undermines the exact structural signal Gemini 3 was trained to parse.
- **Assuming Gemma has a system role** — Gemma 3 and 4 both silently ignore or reject it; instructions must be in the first user turn or they're dropped.
- **Reusing a frontier-tuned prompt verbatim on a small open-weight model** — elaborate multi-part instructions, sparse/generic examples, and complex output schemas that work fine on a 100B+ model reliably regress on a 7–30B local model.
- **Trusting instruction-following at Q2/Q3 quantization for anything agentic or structured** — expect dropped sub-instructions and malformed JSON; step up to Q4_K_M+ before concluding the prompt itself is broken.
- **Sending Gemini 2.5's `thinkingBudget` to a Gemini 3.x model, or `thinkingLevel` to a 2.5.x model** — the two generations use different, non-interchangeable reasoning-control parameters.
- **Verbose, multi-step prompting of a non-thinking-mode model** — prompting DeepSeek V3/V4-Flash (thinking off) or a small Qwen model with `/no_think` the same way you'd prompt a reasoning model wastes tokens for no quality gain; keep non-reasoning-mode prompts short and direct.

## Prompt skeleton

**Gemini (long-context, agentic-capable):**

```
System instruction:
<role>
You are [persona], a precise, direct assistant for [domain].
</role>
<context_notes>
Remember it is 2026 this year — use this for any time-sensitive reasoning or tool calls.
Your training knowledge cutoff is [date]. If the answer isn't in the provided context,
say so explicitly rather than inferring from general knowledge.
</context_notes>
<constraints>
- [Hard constraint 1]
- [Hard constraint 2]
- Verbosity: low. Do not add unrequested caveats, disclaimers, or pleasantries.
</constraints>

User turn (documents FIRST, question LAST — do not reverse this):
<context>
{{all reference documents / code / transcripts go here, in full}}
</context>

Based on the information above:
<task>
[The specific question or instruction, stated once, unambiguous.]
</task>
```

Matching call shape: `model: "gemini-3.6-flash"` (daily) or `"gemini-3.1-pro-preview"` (hard reasoning/complex problem-solving); `thinkingLevel: "low"|"high"` (Gemini 3.x — do not send `thinkingBudget`); `systemInstruction` set to the block above.

**Small open-weight local model (7–30B, single narrow task):**

```
[System — only if the family supports a system role; for Gemma, fold this into
the first user turn instead, since Gemma rejects a system role entirely]
You are a [narrow, single-purpose] assistant. Do exactly one thing: [one task].
Never explain your reasoning. Never add text outside the requested format.

[User]
Task: [one short, concrete instruction — no multi-step chain]
Format: exactly one JSON object shaped like: {"field": "value"}

Example:
Input: [short, real example of the kind of input you've actually seen]
Output: [exact expected output, same shape every time]

Input: {{actual input}}
Output:
```

Matching call shape: correct chat template for the family applied via `apply_chat_template()` (not hand-rolled), `enable_thinking: false` if the family is a hybrid-reasoning model and the task doesn't need it, quant `Q4_K_M` or higher if the task involves structured output or tool calls.

## Sources

- https://ai.google.dev/gemini-api/docs/prompting-strategies
- https://ai.google.dev/gemini-api/docs/thinking
- https://ai.google.dev/gemini-api/docs/models
- https://ai.google.dev/gemini-api/docs/image-understanding
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/prompts/system-instructions
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/long-context
- https://deepmind.google/models/model-cards/gemini-3-1-pro/
- https://www.philschmid.de/gemini-3-prompt-practices
- https://www.secondtalent.com/resources/every-gemini-ai-model-explained-compared/
- https://benchlm.ai/best/google-models
- https://benchlm.ai/compare/gemini-3-1-pro-vs-gemini-3-pro-deep-think
- https://itechify.com/2026/07/22/gemini-3-6-flash-release-no-3-5-pro
- https://ai.google.dev/gemma/docs/core/prompt-structure
- https://ai.google.dev/gemma/docs/core/model_card_4
- https://www.promptingguide.ai/models/gemma
- https://huggingface.co/meta-llama
- https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E-Instruct
- https://www.llama.com/docs/model-cards-and-prompt-formats/llama4/
- https://huggingface.co/Qwen/Qwen3-4B
- https://qwenlm.github.io/blog/qwen3/
- https://github.com/QwenLM/Qwen3/discussions/1300
- https://www.morphllm.com/qwen-3-5
- https://docs.mistral.ai/resources/changelogs
- https://www.promptingguide.ai/models/mistral-7b
- https://api-docs.deepseek.com/updates/
- https://api-docs.deepseek.com/quick_start/pricing
- https://www.techi.com/deepseek-chat-reasoner-retirement-v4-migration/
- https://magazine.sebastianraschka.com/p/technical-deepseek
- https://github.com/sgl-project/sglang/issues/14902
- https://www.hardware-corner.net/quantization-local-llms-formats/
- https://arize.com/blog/how-to-ditch-your-frontier-model-for-an-slm/
- https://developers.redhat.com/articles/2026/02/23/prompt-engineering-big-vs-small-prompts-ai-agents

**Unverified / conflicting claims encountered and excluded:** several low-quality SEO sites (ragyfied.com, andrew.ooo, remoteopenclaw.com) claimed a "Llama 5" (600B params, 5M context) shipped April 2026 — checked against Meta's own `huggingface.co/meta-llama` org page directly, which shows Llama 4 (Scout/Maverick, updated May 2025) as the latest release with no Llama 5 present. Treat "Llama 5" as unverified/likely inaccurate; Llama 4 is the confirmed current open-weight Llama family. Mistral's next open-weight model (teased for "July 2026 early access") had no confirmed parameter count, benchmarks, or license as of this research — treat any specific number for it as unverified.

## Inject
(Compact digest — this is the ONLY section injected into a live prompt. Keep it under ~900 chars; the sections above are human reference.)
- Gemini: pick ONE delimiter convention (XML tags or Markdown headers) and never mix them in a single prompt.
- Gemini: put all reference material FIRST and the actual question LAST, bridged with "Based on the information above...".
- Gemini: put the text prompt BEFORE the image when sending a single image.
- Gemini 3 answers tersely by default — explicitly ask for depth or a conversational tone if you want it.
- Small/local open-weight models: one task per call, a simpler output schema, and concrete examples of the real failure mode. Don't reuse a frontier-tuned prompt verbatim.
- Don't chain multi-step reasoning into one call to a small non-reasoning model — split it into separate steps.
