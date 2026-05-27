# How to Write a Beads Client

Current Beads clients should communicate through the `bd` command-line
interface and request machine-readable output with `--json`. The old
daemon/socket RPC protocol is not the supported integration surface for
`beads-turbo.el`.

## Architecture

```diagram
╭────────────────────╮
│ Client application │
╰─────────┬──────────╯
          │ runs `bd ... --json`
          ▼
╭────────────────────╮
│       bd CLI       │
╰─────────┬──────────╯
          │ uses project metadata
          ▼
╭────────────────────╮
│ .beads/metadata.json│
│ .beads/dolt         │
╰────────────────────╯
```

`beads-turbo.el` also has an optional Dolt SQL read path for fast list,
ready, show, stats, and count operations. The CLI remains the canonical
write path and the fallback for operations that are not implemented by
the direct SQL transport.

## Project Discovery

Discover the current Beads project by finding the metadata sentinel. A
client should not infer a project from unrelated files in `.beads/`.

### Discovery Algorithm

```text
function discoverProjectMetadata():
    if env.BEADS_DIR exists:
        beadsDir = canonicalize(env.BEADS_DIR)
        beadsDir = followRedirect(beadsDir)
        return metadataIn(beadsDir)

    if env.BEADS_DB exists:
        path = canonicalize(env.BEADS_DB)
        if basename(path) == "metadata.json" and exists(path):
            return path

    current = cwd()
    while current != root():
        beadsDir = current + "/.beads"
        beadsDir = followRedirect(beadsDir)
        if metadata = metadataIn(beadsDir):
            return metadata
        current = parent(current)

    return null

function followRedirect(beadsDir):
    redirectFile = beadsDir + "/redirect"
    if exists(redirectFile):
        return readFile(redirectFile).trim()
    return beadsDir

function metadataIn(beadsDir):
    metadata = beadsDir + "/metadata.json"
    if exists(metadata):
        return metadata
    return null
```

The project root is the parent directory of the `.beads/` directory that
contains the metadata sentinel. Run `bd` with that root as the current
working directory so the CLI resolves the same project.

## CLI Contract

Use `--json` for operations that return data. Parse stdout as JSON and
treat a non-zero exit code as an error.

Common commands:

```bash
bd list --json
bd ready --json
bd show <id> --json
bd create "Title" --json
bd update <id> --status in_progress --json
bd close <id> --reason "Done" --json
bd deps <id> --json
bd stats --json
bd count --json
```

For values that may contain shell metacharacters or multiple lines, pass
content through files/stdin or use the CLI flags designed for that field.
Do not build shell strings by concatenation; pass argv entries directly
to the subprocess API in your language.

## Operation Shape

`beads-turbo.el` models client requests as an operation name plus an
argument map, then translates that map to `bd` argv.

Examples:

| Operation | Typical CLI |
|-----------|-------------|
| `list` | `bd list --json` |
| `ready` | `bd ready --json` |
| `show` | `bd show <id> --json` |
| `create` | `bd create <title> --json` |
| `update` | `bd update <id> --status <status> --json` |
| `close` | `bd close <id> --reason <reason> --json` |
| `delete` | `bd delete <id> --force --json` |

Prefer preserving the CLI's JSON field names instead of inventing a
client-specific schema. This keeps client code easy to compare against
`bd <command> --json` output while debugging.

## Minimal Emacs Lisp Example

```elisp
(require 'json)
(require 'subr-x)

(defun my-beads--follow-redirect (beads-dir)
  (let ((redirect (expand-file-name "redirect" beads-dir)))
    (if (file-exists-p redirect)
        (with-temp-buffer
          (insert-file-contents redirect)
          (string-trim (buffer-string)))
      beads-dir)))

(defun my-beads--metadata-in (beads-dir)
  (let ((metadata (expand-file-name "metadata.json" beads-dir)))
    (when (file-exists-p metadata)
      metadata)))

(defun my-beads--find-metadata ()
  (or (when-let ((beads-dir (getenv "BEADS_DIR")))
        (my-beads--metadata-in
         (my-beads--follow-redirect (expand-file-name beads-dir))))
      (when-let ((override (getenv "BEADS_DB")))
        (let ((path (expand-file-name override)))
          (when (and (file-exists-p path)
                     (string= (file-name-nondirectory path)
                              "metadata.json"))
            path)))
      (let ((dir (expand-file-name default-directory))
            found)
        (while (and dir (not found) (not (string= dir "/")))
          (let* ((beads-dir (expand-file-name ".beads" dir))
                 (actual-dir (my-beads--follow-redirect beads-dir)))
            (setq found (my-beads--metadata-in actual-dir))
            (unless found
              (setq dir (file-name-directory
                         (directory-file-name dir))))))
        found)))

(defun my-beads--project-root ()
  (when-let ((metadata (my-beads--find-metadata)))
    (file-name-directory
     (directory-file-name
      (file-name-directory metadata)))))

(defun my-beads--call-json (&rest args)
  (let ((default-directory (or (my-beads--project-root)
                               default-directory)))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process "bd" nil t nil
                              (append args '("--json")))))
        (unless (zerop exit-code)
          (error "bd failed: %s" (string-trim (buffer-string))))
        (goto-char (point-min))
        (json-read)))))

(defun my-beads-list ()
  (my-beads--call-json "list"))

(defun my-beads-show (id)
  (my-beads--call-json "show" id))
```

The production implementation lives in `lisp/beads-client.el` and
`lisp/beads-backend.el`. It adds caching, async dispatch, argument
normalization, richer error wrapping, and optional direct SQL reads.

## Error Handling

Recommended client behavior:

- If project discovery returns `null`, report that no current Beads
  project metadata was found from the selected directory.
- If `bd` exits non-zero, include the trimmed stderr/stdout text in the
  user-facing error.
- Retry only transient transport failures. Do not retry validation
  errors such as unknown issue IDs, invalid statuses, or dependency
  cycles.
- Clear any project-discovery cache when environment overrides change
  or when a caller explicitly asks to refresh project state.

## Summary

1. Locate `.beads/metadata.json`, respecting `BEADS_DIR`, `BEADS_DB`,
   and `.beads/redirect`.
2. Derive the project root from that metadata path.
3. Run `bd` from the project root with `--json`.
4. Parse stdout as JSON and surface non-zero exits as errors.
5. Use direct Dolt SQL only as an optional read acceleration layer.
