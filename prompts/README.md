# prompts/ — Senti's private knowledge base

The prompting knowledge that makes Senti worth paying for. **Private. Never make public.**

- `prompts/models/*.md` — per-model prompting guidance. Frontmatter carries `family`,
  `match` (regex against the frontmost app / window title), `display_name`, `frontier`,
  `daily`. Only the `## Inject` digest is sent at runtime (~900B); the research prose
  below it is human reference and must stay out of the live prompt.
- `prompts/prompt-craft.md` — shared craft layer, both prompt paths.
- `prompts/operating.md` — behavior layer prepended to every AI mode.

This used to be its own repo (`senti-kb`, 2026-08-19 to 2026-10-17); it now lives inside the
Senti repo with its history. `install.sh` deploys it to `~/.config/senti/prompts/`. Before the
repo is ever made public, split this folder out (see CLAUDE.md).

In production this is served from `/api/kb` against a license key — it is the paid artifact.
