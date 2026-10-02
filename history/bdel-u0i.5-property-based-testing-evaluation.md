# Property-based testing evaluation

Issue: `bdel-u0i.5`

Date: 2026-10-02

## Decision

Adopt property-based testing experimentally for pure issue-list transformations,
not as a replacement for ERT examples or integration tests.

The first pilot should exercise `beads-list-data-sectioned-sort` and
`beads-list-data-compute-stats` with generated issue alists.  Keep the pilot out
of the required `make check` gate until failures have a copyable replay token
that works in a fresh Emacs process.  If that replay support is added,
[`Wilfred/propcheck`](https://github.com/Wilfred/propcheck) is the most practical
starting point: it expands properties to ERT tests and includes automatic
shrinking without adding a non-Elisp runtime.

Do not integrate Hegel now.  It has no Emacs Lisp frontend, and its current
engine is an in-process native C ABI rather than the retired language-neutral
server protocol.  Building an Emacs module, generator API, native packaging,
and ERT adapter would overwhelm the value of this pilot.

## Why PBT fits selected parts of beads-turbo

The best targets are pure functions with many interacting dimensions and a
small behavioral specification.  The list model receives statuses, priorities,
dependency counts, timestamps, marks, filters, duplicate IDs, missing parents,
and parent cycles.  A few hand-authored fixtures cover examples of those cases;
generated asymmetric combinations can check that every combination preserves
the same general rules.

PBT is less useful when the important contract is a single exact fact.  A key
must invoke one command, a SQL query must use the current beads schema, and an
error must be translated in a particular way.  Replacing such examples with a
generator would make the contract less obvious without expanding meaningful
coverage.

## Candidate invariants

### 1. Filter algebra — high value, low setup cost

For generated issue lists and generated status/type/priority/assignee filters:

- every filtered result is an input element and preserves input order;
- identity returns the original sequence;
- applying a filter twice is the same as applying it once;
- `compose(A, B)` equals applying `A` and then `B`;
- `compose-or(A, B)` is the stable union of the two result sets;
- `negate(A)` partitions the input with `A` without omissions or overlap;
- `beads-filter-from-state` agrees with an independently written reference
  predicate, rather than with another call through the production helpers.

These properties are stronger than adding one fixture for every filter
combination.  Generators should include absent optional fields, nil assignees,
empty labels, mixed statuses, and unequal category frequencies.

### 2. List model, statistics, and section sorting — best pilot

For `beads-list-data-build`, `beads-list-data-compute-stats`, and
`beads-list-data-sectioned-sort`:

- sorting preserves the exact multiset of issue records, including duplicates;
- output section numbers are nondecreasing: unblocked, blocked, then closed;
- in-progress issues precede other unblocked issues;
- priorities are nondecreasing within the in-progress, other-unblocked, and
  blocked subgroups;
- closed timestamps are nonincreasing within the closed subgroup;
- filter and marked-only outputs are subsets of the preceding pipeline stage;
- stats describe the original input, not a filtered or marked subset;
- every stat is nonnegative and bounded by total issues;
- all counts agree with a small independent fold over the generated input.

Do not derive expected counts with `beads-list-data-issue-section` or another
production helper: that would reproduce the same bug in the oracle.

Sorting idempotence is deliberately excluded until tie behavior is specified.
The live experiment found that two same-priority open issues can reverse on a
second sort because the comparator has no tie-breaker.  That is not necessarily
a defect—the current API does not promise stable ties—but it demonstrates that
properties are executable product decisions, not generic mathematical slogans.

### 3. Flat-list to forest conversion — high value, second pilot

Generate bounded parent graphs containing missing parents, self-parenting,
duplicate IDs, and cycles.  Check:

- every first occurrence of a non-nil ID appears exactly once in the forest;
- later duplicate IDs never replace the first issue record;
- every output node is reachable from exactly one root;
- following child links terminates, so the output contains no cycle;
- a linked child's normalized parent ID equals its containing parent's ID;
- nodes with absent parents remain roots and preserve their parent metadata;
- sibling and root order follows first occurrence in the input;
- filtering away a parent cannot remove its retained child.

Generate valid acyclic graphs by construction for ordinary coverage, then mix
in explicit cycle/duplicate mutations.  Filtering arbitrary graphs until they
happen to be valid wastes examples and makes shrinking poor.

### 4. UI rendering and navigation — useful after pure pilots

For generated display models rendered into temporary buffers:

- each displayed issue ID has exactly one navigable region;
- navigation never lands on a section heading when issue rows exist;
- text properties retain the full issue object even when visible text is
  truncated or contains punctuation and non-ASCII text;
- refreshing with the same selected ID restores that ID when it remains and
  lands on a valid issue when it does not;
- rendering an empty model leaves no stale issue properties.

These are appropriate buffer-level properties, but failures will be harder to
shrink than pure alists.  They should follow, not precede, the list-model pilot.

### 5. Stateful and backend properties — defer

State-machine properties could generate filter/set/clear sequences and compare
`beads-state` with a simple reference state.  Differential tests could compare
CLI and SQL normalization against the same disposable project.  Both may be
valuable later, but they add global state, subprocesses, version drift, and
expensive shrinking.  They are outside the bounded pilot.

PBT should not generate SQL text and assert its shape.  Existing exact schema
assertions should remain examples; semantic backend equivalence belongs in
focused integration tests.

## Tooling evaluation

### `propcheck`

The evaluated revision was
[`2107579`](https://github.com/Wilfred/propcheck/commit/21075792c03a186bc89029871c6db119e6e13cf0)
(2025-05-04).  Upstream labels the project beta.

Strengths:

- `propcheck-deftest` expands directly to `ert-deftest`, so the existing batch
  runner, selectors, backtraces, and exit status continue to work;
- the default is 100 examples and up to 200 shrink attempts;
- built-in generators cover booleans, bounded integers, choices, lists,
  vectors, ASCII strings, characters, and floats;
- composite issue generators can be built with list `:value-fn` callbacks;
- failures report the minimized named generated values.

Constraints:

- it requires `dash` 2.18.1, which is not available in this repository's
  current `emacs -Q` test environment;
- it is not distributed through MELPA, so both source revisions need an
  explicit pin or vendoring decision;
- there are no first-class alist, recursive tree, weighted, bind, or filtered
  generators;
- strings are ASCII-only and float generation is documented as incomplete;
- shrinking mutates an internal byte stream rather than using domain-aware
  issue/tree shrinkers, so generator encoding materially affects results;
- the public failure report does not include the raw seed bytes, and
  `propcheck-deftest` does not accept a documented replay token.  It can replay
  internally while shrinking, but not conveniently across CI processes.

The last limitation is the gate for adoption.  A tiny local adapter or upstream
patch should serialize the final seed bytes, accept a `BEADS_PBT_REPLAY` value,
and prove replay in a fresh batch Emacs.  Merely seeding Emacs's global random
state is fragile because unrelated random calls can change the sequence.

### Hegel and Hypothesis

[Hegel](https://hegel.dev/) currently lists Rust, Go, C++, TypeScript, Java,
and OCaml frontends, but no Emacs Lisp frontend.  Its current
[`libhegel` interface](https://hegel.dev/reference/libhegel/) provides strong
seed and reproduction-blob support through a native shared library.  The old
[`hegel-core`](https://github.com/hegeldev/hegel-core) server is explicitly
retired.

Calling Python Hypothesis from ERT would similarly require a bidirectional
protocol that lets Python generate and shrink values while repeatedly invoking
the Elisp system under test.  Maintaining that bridge and process lifecycle is
not justified for pure functions that can run directly in ERT.  Reconsider
Hegel if it gains an official Elisp frontend or a supported subprocess
protocol.

### A project-local random loop

An ERT helper using a deterministic random state would avoid dependencies and
can be useful for an exploratory fuzz test.  It would not provide automatic
shrinking, generator composition, or a mature replay model.  Implementing those
features locally would create a testing framework inside this package.  Prefer
a pinned `propcheck` pilot plus a small replay adapter over such a framework.

## Live experiment

A throwaway test loaded `propcheck` and `dash` from pinned checkouts and
generated compact issue alists for `beads-list-data-sectioned-sort` on Emacs
31.1.  No repository runtime code was changed.

- 100 generated examples checking exact multiset preservation and monotonic
  section order passed in 14–22 ms of ERT time across five fresh runs.
- Complete fresh Emacs processes took 0.30–0.33 seconds each.
- A deliberately false integer-list property shrank and reported
  `(values 1 0 0 0)` in 9 ms, demonstrating useful minimal-value reporting.
- Adding sort idempotence produced a two-issue counterexample, revealing the
  unspecified tie-order behavior described above.

These timings are feasibility observations, not a stable benchmark.  The pilot
should enforce a generous ceiling (for example, under one second inside the
existing batch process) rather than depending on these exact numbers.

## Tests that should remain example-based

Keep ordinary ERT examples for:

- keymaps, command registration, mode derivation, and exact user-visible text;
- known regression cases whose minimized inputs explain a fixed bug;
- SQL schema columns, joins, parameter binding, and backend command dispatch;
- error translation and exact side-effect ordering;
- one or two readable examples for every public behavior covered by a property;
- real `bd`/Dolt integration and destructive temporary-project workflows;
- layout snapshots and rendering cases where visual intent is the contract.

When a property discovers a bug, add its minimized counterexample as a normal
ERT regression test.  This preserves the finding even if generators or the PBT
tool change later.

## Bounded pilot

Add one opt-in file, `test/beads-list-data-property-test.el`, without migrating
or deleting existing tests.

Scope:

1. Pin reviewed `propcheck` and `dash` revisions using the repository's existing
   test-dependency approach.
2. Add fresh-process serialization/replay and print the replay token on failure.
3. Generate lists of 0–30 issue alists with mixed statuses, priorities,
   dependency counts, and closed timestamps.
4. Check sort multiset preservation, section ordering, within-section ordering,
   and stats against an independent fold for 100 examples.
5. Run locally through a focused script or Make target before adding it to
   `make check`.

Success criteria:

- the same token reproduces a deliberately failing property in two fresh Emacs
  processes;
- an injected plausible comparator/counting fault is caught and shrinks to a
  readable counterexample;
- 100 examples complete in under one second inside the batch process;
- failure output names the generated issues and the violated invariant;
- generator/helper code stays smaller than the properties it supports;
- no production package dependency or live beads database is introduced.

Migration boundary:

- do not delete current examples during the pilot;
- do not cover buffers, global state, subprocesses, SQL, or integration tests;
- do not add randomized tests to the required gate until replay is proven;
- stop the pilot if dependency/replay glue is larger or less diagnosable than
  the list-model properties;
- after a month of normal CI use or at least one useful discovered
  counterexample, decide whether to add forest properties as a second phase.

## Revisit criteria

Expand PBT only when the pilot demonstrates reproducible, readable failures at
low runtime cost.  Reconsider tooling if `propcheck` gains first-class replay or
domain generators, another maintained native Elisp framework appears, or Hegel
ships an official Emacs frontend.
