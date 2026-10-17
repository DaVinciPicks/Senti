# senti-kb — private knowledge base

The prompting knowledge that makes Senti worth paying for. **Private. Never make public.**

- `prompts/models/*.md` — per-model prompting guidance. Frontmatter carries `family`,
  `match` (regex against the frontmost app / window title), `display_name`, `frontier`,
  `daily`. Only the `## Inject` digest is sent at runtime (~900B); the research prose
  below it is human reference and must stay out of the live prompt.
- `prompts/prompt-craft.md` — shared craft layer, both prompt paths.
- `prompts/operating.md` — behavior layer prepended to every AI mode.

The public app repo (`DaVinciPicks/Sanele`) gitignores `prompts/`. Clone this beside it,
or symlink, so `install.sh` can deploy the KB locally.

In production this is served from `/api/kb` against a license key — it is the paid artifact.
