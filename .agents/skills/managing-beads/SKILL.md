---
name: managing-beads
description: "Manages bd issues safely, including creating collision-resistant epic children, linking discovered work, claiming tasks, and closing completed issues. Use whenever creating or changing beads issues or deciding between parent-child and discovered-from dependencies."
compatibility: "Requires a bd-initialized workspace with a reachable Dolt database."
---

# Managing Beads

Use `bd` as this repository's source of truth for persistent work. Run `bd prime` when the live CLI reference is needed, and use `--json` for programmatic reads.

## Start Work

Pull the current task graph before selecting or changing work:

```bash
bd dolt pull
bd ready --json
bd show <id> --json
bd update <id> --status in_progress --json
```

Do not claim an issue before reading it. Preserve changes from other clones and agents.

## Choose the Correct Relationship

Inspect the proposed parent before creating related work:

```bash
bd show <parent-id> --json
```

Use hierarchy only when `issue_type` is `epic`. Create an epic child and its dependency atomically:

```bash
bd create "<title>" \
  --type task --priority 2 \
  --deps "parent-child:<epic-id>"
```

This produces a collision-resistant flat hash ID such as `bdel-a1b2`. Do not use `bd create --parent` in concurrent clones or independently synced workspaces: it assigns sequential IDs such as `<parent>.1`, and separate clones can assign the same ID.

Never attach `parent-child` to a task, bug, or other non-epic. `bd close` refuses to close a parent with open children. For work discovered while completing a non-epic, create a new top-level issue with a non-blocking provenance link:

```bash
bd create "<follow-up title>" \
  --type task --priority 2 \
  --deps "discovered-from:<source-id>"
```

Either keep the source issue open until its own scope is complete or close it after filing the follow-up. Existing sequential child IDs remain valid and do not need migration.

## Preserve Labels and Rich Text

`--deps parent-child:<epic-id>` does not inherit labels. Pass each required label explicitly with `-l` / `--labels`; do not switch to `--parent` just to inherit them.

Use stdin for descriptions containing shell-sensitive text:

```bash
bd create "<title>" \
  --type task --priority 2 \
  --deps "parent-child:<epic-id>" \
  --body-file - <<'EOF'
Description with `backticks`, "quotes", $(literals), and ! preserved.
EOF
```

For notes, use a shell variable because `--stdin` aliases description input:

```bash
notes=$(cat <<'EOF'
Verification and handoff notes.
EOF
)
bd update <id> --append-notes "$notes"
```

## Finish Work

Run the narrowest meaningful quality gate, record useful evidence, close the issue, and sync the task graph:

```bash
bd close <id> --reason "<completed outcome>"
bd dolt commit -m "<issue-id>: <outcome>"
bd dolt push
bd show <id> --json
```

If work remains, create the correct relationship before closing: `parent-child` only from an epic, otherwise a top-level issue linked with `discovered-from`.
