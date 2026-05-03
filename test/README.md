# Test Directory

This directory contains ERT (Emacs Lisp Regression Testing) tests for beads.el.

## Running Tests

```bash
make test
```

## Writing Tests

Test files should:
- End with `-test.el` suffix
- Use `(require 'ert)` at the top
- Define tests using `ert-deftest`

Example:

```elisp
(require 'ert)

(ert-deftest beads-feature-test ()
  "Test that feature works correctly."
  (should (equal (some-function) expected-result)))
```

## ERT Assertions

- `(should CONDITION)` - Assert that condition is true
- `(should-not CONDITION)` - Assert that condition is false
- `(should-error BODY)` - Assert that body signals an error
- `(should-error BODY :type 'error-type)` - Assert specific error type

## Test Organization

- Unit tests: Test individual functions in isolation
- Integration tests: Test component interactions (require bd CLI)

See `example-test.el` for basic examples.

## Supported Beads Versions

This package is tested with **bd 0.49.1**. Tests may not reflect
behavior of older or newer beads CLI versions.

| beads.el | beads CLI | Storage Backend           |
|----------|-----------|---------------------------|
| current  | 0.49.x    | Dolt (metadata.json)      |
| legacy   | pre-1.0   | JSONL files + SQLite (.db)|

## Storage Backend Discovery Priority

The `beads-client--find-database` function discovers a beads project
by checking for these sentinels in order:

1. `metadata.json` — primary sentinel (Dolt backend, also present in some SQLite setups)
2. `beads.db` — legacy SQLite fallback
3. Any `.db` file (excluding `vc.db` and `*.backup`) — last-resort fallback

## Test Compatibility Notes

- **Discovery tests** (`beads-client-test.el`): Reflect the Dolt-first priority.
  Legacy `beads.db` fallback is tested separately. The legacy `.db` extension
  scanning test was removed.
- **Activity tests** (`beads-activity-test.el`): Preserved but documented as
  testing only the Emacs Lisp rendering layer. The `bd activity` subcommand
  does not exist in bd 0.49.x (see bdel-a6p).
- **All other test files**: Storage-backend agnostic. Test Emacs Lisp logic
  only (modes, keybindings, rendering, state management).
