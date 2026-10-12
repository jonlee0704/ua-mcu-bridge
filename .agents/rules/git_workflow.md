# Multi-Agent Git Workflow (mandatory)

JY works on this repo with several agents at once (Antigravity, Claude Code local, Claude Code web). GitHub is the only shared state. Full details are in AGENTS.md section 1.

1. Never commit directly to `main`. Make one branch per task, prefixed by who made it:
   - `ag/<topic>` for Antigravity
   - `claude/<topic>` for Claude
   - `jy/<topic>` for JY
2. Before starting, run `git fetch origin && git switch main && git pull --ff-only`, then create your branch.
3. Push your branch at the end of every session, even unfinished work.
4. Merge into `main` only through a pull request. JY reviews and merges.
5. Never push to another agent's branch.
6. After `main` moves, rebase your open branch with `git pull --rebase origin main`.
7. Never commit secrets: built binaries, audio files, logs, credentials.
