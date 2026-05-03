# Agent Instructions

## Beads Version Compatibility

This package is tested with **bd 1.0.3**. Run `/beads-compat` to check.

## Issue Tracking with bd (beads)

This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs or external trackers.

**Workflow reference**: Run `bd prime` for the full command reference and session protocol.

**Quick workflow:**
1. `bd dolt pull` - get latest task graph issues from dolt remote
2. `bd ready --json` — find unblocked work
3. `bd update <id> --status in_progress` — claim it
4. Implement, test, document
5. `bd close <id> --reason "Done"` — complete it
6. `bd dolt commit -m "commit message"` - commit changes
6. Discover new work? `bd create "Found bug" -p 1 --deps discovered-from:<parent-id>`
7. `bd dolt push` - push local task graph data to dolt remote

**Key rules:**
- Always use `--json` for programmatic use
- Link discovered work with `discovered-from` dependencies
- Store AI planning docs in `history/` directory, not repo root
- `bd <cmd> --help` to discover available flags

### Shell-Safe bd Description Input
When `bd create`/`update` descriptions or notes contain backticks, `!`, `$(...)`, quotes or multiline text, use `--stdin` heredoc (or `--body-file -`) to prevent shell interpolation:

```bash
bd create "Title" --stdin <<'EOF'
Description with `backticks`, "quotes", ! and $(literal) preserved.
EOF

# For notes without --stdin flag:
notes=$(cat <<'EOF'
...
EOF
)
bd update <id> --append-notes "$notes"
```

## Quality Gates

Run before every commit when code has changed:

| Command | What it does |
|---------|-------------|
| `make check` | Lint + test (full gate) |
| `make lint` | Check syntax/parens, byte-compile all `.el` files |
| `make test` | Run ERT test suite |
| `make build` | Byte-compile all `.el` files |
| `make interactive` | Launch Emacs with beads.el loaded for manual testing |
| `make new-test FEATURE=<name>` | Scaffold a new test file |

**Testing requirement**: All new functionality must include corresponding ERT tests in the `test/` directory

## Session Completion

Work is NOT complete until `git push` succeeds:

```bash
git pull --rebase
git push
git status  # MUST show "up to date with origin"
```
