## What this changes

<!-- One or two sentences on the behaviour change. -->

## How you checked it

<!-- Paste the commands and their last lines. -->

- [ ] `for f in senti-*.sh install.sh uninstall.sh app/*.sh; do /bin/bash -n "$f"; done` passes
- [ ] `bash senti-selftest.sh --ci` ends with "All N checks passed."
- [ ] If runtime behaviour changed: `./install.sh`, then the installed self-test

## Rules (see CONTRIBUTING.md)

- [ ] Speech, system prompts, window titles and keys stay off the command line (the argv rule)
- [ ] Any new file under `~/.cache/senti` is covered by `wf.sweepSensitive`
- [ ] No key, `*.pref`, `eval/history.csv`, real name, email address or full home-folder path in the diff
- [ ] `README.md` updated if modes, permissions or install steps changed; `PRIVACY.md` if what leaves the Mac changed
- [ ] Docs follow the style rules: plain sentences, digits, no em or en dashes, claims traced to code or a dated check
