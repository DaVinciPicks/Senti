---
name: Bug report
about: Something in Senti does not work as described
title: ""
labels: bug
---

<!--
Security problem? Do not file it here. See SECURITY.md.

Before you paste anything: remove API keys. If a line shows part of a key, replace it,
for example sk-...abcd. Also remove anything private, such as note names or window titles.
-->

**What happened**

**What you expected**

**Steps to reproduce**

1.
2.
3.

**Mode**

Dictate (right Option), Prompt (right Command), Command (Fn), Context (Control Option V), install,
uninstall, or other:

**Your Mac**

- macOS version (Apple menu, About This Mac):
- Chip (for example M1, M3 Pro):
- Senti version or commit (`git -C <your checkout> log --oneline -1`):
- AI provider and model, if an AI mode is involved (`bash ~/.config/senti/senti-key.sh status`
  prints them, with only the last 4 characters of each key):

**Self-test output**

From your checkout, offline: `bash senti-selftest.sh --ci`
If Senti is installed: `WF_SELFTEST_OFFLINE=1 bash ~/.config/senti/senti-selftest.sh`

```
paste here, with keys removed
```

**Log lines, if relevant**

The last lines of `~/Library/Logs/senti.log` around the problem. The log holds counts, not your
words, unless you set `WF_DEBUG=1`; if you did, remove the text before pasting.

```
paste here
```
