# CLAUDE.md

All project instructions live in AGENTS.md (shared with Antigravity and other agents). Edit AGENTS.md, not this file.

@AGENTS.md

## Claude-specific notes
- Use `claude/<topic>` branches. From a cloud session, deliver work as a PR against `main`. Never push to `main` or to `ag/*` branches.
- When running locally next to Antigravity, work in a separate git worktree.
- The P0 testing rule applies to you: add or extend tests in `Tests/` for every change. In a cloud session without macOS, say clearly in the PR that `./run_tests.sh` still needs to be run.
