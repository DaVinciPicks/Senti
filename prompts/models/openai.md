---
family: openai
display_name: OpenAI GPT-5.x
match: gpt-5|gpt5|chatgpt|openai|codex|o3|o4
frontier: gpt-5.6-sol
daily: gpt-5.6-terra
updated: 2026-08-09
---

## Prompting rules

1. Set `reasoning.effort` explicitly on every call — don't rely on the model default (`medium`). Use `low`/`medium` for interactive/latency-sensitive turns, `high`/`xhigh` for hard multi-step or coding tasks, `max` (GPT-5.6 only) for the hardest quality-first work.
2. Never add "think step by step," "reason through this carefully," or manual chain-of-thought scaffolding. GPT-5.x already runs internal reasoning before answering; explicit CoT requests are redundant at best and create conflicting internal reasoning at worst.
3. Write single, unambiguous instructions instead of soft or overlapping ones. GPT-5.x's high instruction-adherence means it burns reasoning tokens trying to *reconcile* contradictions rather than just picking one and moving on (which is what GPT-4o-class models did) — vague prompts cost more here, not less.
4. Use the `verbosity` parameter for default output length, then override it in-prompt only for the specific sub-parts that need to deviate (e.g. "use high verbosity only inside code blocks"). This is the officially-demonstrated pattern (Cursor's GPT-5 integration).
5. Start every prompt lean — the smallest version that encodes the task — and add an instruction or example only when a failing eval demonstrates it's needed. OpenAI measured ~10-15% eval gains and 40-65% token/cost cuts on GPT-5.6 just from deleting accumulated defensive system-prompt cruft.
6. State each rule once, in one place. Repeated reminders ("ask first," "don't do X," restated three times) read as extra constraints the model must reconcile, and can trigger unwanted over-cautious behavior.
7. For agentic/tool-using tasks, explicitly define autonomy boundaries: which actions the model should take without asking, and which require confirmation. GPT-5.x defaults toward proactive, unattended tool use unless scoped.
8. Migrating a prompt from GPT-4o: start with `reasoning.effort: none` as the baseline (closest to non-reasoning behavior), run your evals, then raise effort one level at a time. Don't carry over GPT-4o-era chain-of-thought or role-play framing verbatim.
9. Migrating between GPT-5.x generations (5.4 → 5.5 → 5.6, etc.): start from a fresh minimal prompt rather than reusing the old one. OpenAI's own guidance: treat each new generation "as a new model family to tune for, not a drop-in replacement."
10. For long-running or multi-tool turns, instruct the model to emit a short (1-2 sentence) user-visible acknowledgment before its first tool call. This masks reasoning latency so the app doesn't read as hung.
11. Put durable behavior in one `instructions` field (Responses API) or one system/developer message — don't split the same policy across a system message and a separate developer message in the same request.
12. At `minimal`/`low` reasoning effort specifically, add "briefly summarize your plan before the final answer." Minimal/low-effort reasoning is far more prompt-sensitive than medium/high, and this one line recovers most of the quality gap.
13. To force a specific output shape, use `strict: true` on a JSON schema (function tool or `text.format`) — don't rely on prose instructions like "respond only in JSON." Strict mode is decode-time enforced; prose is not reliable, even for reasoning models.
14. Don't reflexively add few-shot examples to fix a tool-calling prompt. OpenAI's own function-calling guide warns examples "may hurt performance for reasoning models" — add one only to patch a demonstrated recurring failure, not as a default technique carried over from GPT-4o/GPT-4.1.

## Controls

| Param | Valid values | Use when |
|---|---|---|
| `reasoning.effort` (Responses) / `reasoning_effort` (Chat Completions) | `none`, `minimal`*, `low`, `medium`, `high`, `xhigh`, `max`† — *`minimal` only exists on the original GPT-5 snapshots (`gpt-5`, `gpt-5-mini`, `gpt-5-nano`); rejected on GPT-5.1 and later (confirmed rejected on `gpt-5.4-mini`). †`max` only on GPT-5.6. | `low`/`medium` for latency-sensitive or simple tasks; `high`/`xhigh` for hard reasoning, debugging, deep planning; `max` for the hardest quality-first work when `xhigh` isn't enough. |
| `text.verbosity` | `low`, `medium`, `high` | Controls final-answer length only, independent of reasoning depth. Low for terse UI text; high for code output / detailed explanations. |
| `reasoning.mode` (GPT-5.6 only) | `standard`, `pro` | `pro` trades latency/cost for quality on the *same* model slug — don't switch models to get "pro" behavior. Independent of `effort`. |
| `reasoning.context` | `auto`, `current_turn`, `all_turns`† (†GPT-5.6 only, and its default) | `all_turns` preserves prior reasoning across a multi-turn agentic loop when goals/assumptions stay stable turn to turn. |
| `store` + `previous_response_id` | `true`/`false`, response id | Keep `store: true` and pass `previous_response_id` to preserve hidden reasoning state across turns (Responses API). Use encrypted `reasoning` items instead if on Zero Data Retention. |
| `text.format` (Responses) / `response_format` (Chat Completions) | `{"type": "json_schema", "schema": ..., "strict": true}` | Force a JSON output shape — the recommended mechanism, not prompt instructions. |
| `tool_choice` + function `strict: true` | `auto`/`required`/`none`/named tool; `strict: true` | Force or guarantee a specific, schema-conformant tool call. |
| `prompt_cache_key` / prefix ordering | any string / static-content-first prompt structure | Cheaper + faster repeat calls; put static instructions first, dynamic user content last. |

## Anti-patterns

- **"Think step by step" / explicit CoT requests** — redundant with built-in reasoning; can create internally contradictory reasoning traces. Helped GPT-4o, actively wastes reasoning tokens on GPT-5.x.
- **Long, accumulated "just in case" system prompts** — every restriction ever needed for a past failure, kept forever. OpenAI measured this costing 10-15% eval quality and 40-65% extra tokens on GPT-5.6 versus a lean, current prompt.
- **Contradictory or overlapping instructions** — harmless on GPT-4o (it just picks one and moves on); expensive on GPT-5.x, which spends reasoning tokens trying to reconcile the irreconcilable and can under-perform on both halves.
- **Heavy few-shot example blocks for tool calling** — useful for GPT-4o/GPT-4.1; OpenAI's own docs warn examples "may hurt performance for reasoning models."
- **"Be thorough, gather full context before replying" boilerplate** — Cursor found this counterproductive on GPT-5: the model is already proactive/introspective by default, and the instruction caused it to over-call search tools on simple tasks that needed none.
- **Reusing an old prompt verbatim across GPT-5.x generations** — OpenAI explicitly warns against treating 5.5/5.6 as drop-in replacements for 5.2/5.4; stale `reasoning.effort` and verbosity assumptions carry over silently.
- **Chat Completions + tools + nonzero reasoning effort on GPT-5.6+** — now a hard API error ("Function tools with reasoning_effort are not supported ... in /v1/chat/completions"). Use the Responses API for tool calling, or set `reasoning_effort: none` if you must stay on Chat Completions.
- **Treating `reasoning.effort` as the first fix for a quality problem** — OpenAI's own advice: treat it as a tuning knob, not the primary lever. Fix the prompt/instructions first, then tune effort.
- **Assuming `verbosity` controls thinking depth** — it only shapes the length of the final answer, not how much the model reasons. Use `reasoning.effort` for depth.

## Prompt skeleton

```
<context>
[One or two sentences: who the assistant is, the product/task domain.]
</context>

<task>
[Single, unambiguous statement of what to do. State each instruction once — no restatement, no accumulated caveats.]
</task>

<constraints>
- [Hard constraint 1]
- [Hard constraint 2]
</constraints>

<autonomy>
For requests to explain, review, diagnose, or plan: inspect and report — do not change anything.
For requests to change, build, or fix: make the requested in-scope changes without asking first;
escalate only when [specific condition].
</autonomy>

<output_format>
[Exact shape expected: plain text, markdown, or a named JSON schema. Do not restate "be concise" if
verbosity is already set via the API param — state only task-specific length/structure requirements.]
</output_format>
```

Matching API call shape:

```python
response = client.responses.create(
    model="gpt-5.6-terra",              # gpt-5.6-sol for the hardest tasks; gpt-5.6-luna for high-volume/cheap
    reasoning={"effort": "medium"},      # none/low/medium/high/xhigh/max — tune per task, not left at default
    text={"verbosity": "low"},
    instructions=SYSTEM_PROMPT,          # single source of truth, not split across messages
    input=user_input,
    store=True,                          # + previous_response_id next turn to preserve reasoning state
)
```

## Sources

- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide
- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5-1_prompting_guide
- https://github.com/openai/openai-cookbook/blob/main/examples/gpt-5/gpt-5-2_prompting_guide.ipynb
- https://developers.openai.com/api/docs/guides/latest-model
- https://developers.openai.com/api/docs/guides/reasoning
- https://developers.openai.com/api/docs/guides/migrate-to-responses
- https://developers.openai.com/api/docs/guides/prompt-caching
- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/models (+ /models/gpt-5.6-sol)
- https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning
- https://openai.com/index/gpt-5-6
- https://en.wikipedia.org/wiki/GPT-5.6
- https://github.blog/changelog/2026-07-09-openais-gpt-5-6-sol-terra-and-luna-are-now-available-in-github-copilot
- https://simonwillison.net/2026/apr/25/gpt-5-5-prompting-guide
- https://openai.com/index/introducing-structured-outputs-in-the-api
- https://the-decoder.com/openai-publishes-prompting-guide-for-gpt-5-1/
- https://hidekazu-konishi.com/entry/openai_gpt_model_release_timeline.html
- https://aiwiki.ai/wiki/openai_responses_api

## Inject
(Compact digest — this is the ONLY section injected into a live prompt. Keep it under ~900 chars; the sections above are human reference. Distilled from the rules and anti-patterns above.)
- Do NOT add "think step by step" or any hand-written reasoning scaffold: GPT-5.x reasons internally, so explicit CoT wastes reasoning tokens and can conflict with it.
- State each instruction once, unambiguously. Overlapping or contradictory instructions are expensive here — the model spends reasoning tokens reconciling them.
- Keep the prompt lean. Do not add defensive "just in case" clauses or "be thorough, gather full context" boilerplate; it makes the model over-call tools on simple tasks.
- Define autonomy explicitly for tool/agent work: what to do without asking vs what needs confirmation.
- Force output shape with an explicit schema instruction, not prose pleading like "respond only in JSON".
- Don't pile on few-shot examples for tool use; on reasoning models they can hurt.
