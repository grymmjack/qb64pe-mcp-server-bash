# NOTES — findings & gotchas for this MCP server

Durable notes so we don't re-learn the same things. OS-stamped per the repo convention.

## [Linux] `qb64pe -z <ENTRY>.BAS` is a fast, reliable syntax gate (2026-09-04)

Working on the DRAW project (a ~170k-line QB64-PE codebase, entry `DRAW.BAS`):

- **`qb64pe -z DRAW.BAS`** (transpile BASIC→C++ only, no g++/link) measured **~100s**
  vs **~13min** for the full `qb64pe -x DRAW.BAS` build — **~8× faster** — and it is
  **reliable**: it walks the same include chain + preprocessor state as `-x`, so a clean
  `-z` means the real build's front-end is clean, and any `-z` error is a real `-x` error.
  It catches the whole syntax / reserved-word / string-literal / arg-count class.
  → Recommend `-z <entry>.BAS` as the everyday pre-build gate.

- Errors it caught in one session (each ~100s vs a failed ~13min build): `out` used as a
  variable (collides with the `OUT` statement); `""` inside a string is NOT an escaped
  quote in QB64-PE (it reads two juxtaposed literals — use single quotes in HTML or
  `CHR$(34)`); a no-arg `FUNCTION Foo$` must be CALLED without parens (`Foo$`, not `Foo$()`).

### ⚠️ Divergence to investigate in `lib/lint.sh`

The `lint` tool's Layer A, given `projectEntry: DRAW.BAS`, runs
`qb64pe -z $eflag -w -m -q DRAW.BAS` (lib/lint.sh:28, target set at :131-132). In that
session it reported a **spurious** error — `Invalid variable name … T0 = _UPTIME` in the
**untouched** `CORE/PERF.BM` — that a **plain `qb64pe -z DRAW.BAS` (no `-w -m -q`) does NOT
produce** (the plain run sailed past PERF.BM and flagged only the real errors in the edited
file). So the added flags (most likely `-w`, possibly `$eflag`/`-e`) appear to change error
reporting vs. a plain `-z`. Until this is pinned down, prefer a plain `qb64pe -z <entry>.BAS`
for a trustworthy compiler gate on a large project; treat the tool's projectEntry Layer-A
output with suspicion when it flags a file you did not touch.

Also note (already known): Layer B's "self-reference SIGSEGV" regex FALSE-flags every
`CASE x : FUNC$ = "..."` assignment — those are FUNCTION returns (LHS), not recursive reads
(RHS). The rule should not fire when the function name is the assignment target.

### Future: per-file gate via an include DAG

To gate a single `.BM` in seconds (not 100s), build a symbol→file dependency graph and
generate a minimal harness: all `.BI` (declarations are cheap) + the target `.BM` +
`DECLARE`s for the cross-`.BM` SUB/FUNCTIONs it calls (QB64 `-z` errors on an undefined
SUB, so the callees need bodies or DECLAREs). Watch QB64's finicky non-LIBRARY `DECLARE`
and `$INCLUDEONCE` path normalization. Would let the tool's fragment mode be both fast and
false-positive-free.
