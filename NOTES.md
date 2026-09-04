# NOTES — findings & gotchas for this MCP server

Durable notes so we don't re-learn the same things. OS-stamped per the repo convention.

## [Linux] CORRECTION: `-z` is NOT a faster error-gate than `-x` (2026-09-04)

An earlier version of this note claimed `qb64pe -z DRAW.BAS` is "~8× faster" and a great
pre-build syntax gate. **That was a bad comparison** (a *failed*, short-circuited `-z` vs a
*successful* full `-x`). Corrected understanding, verified on the DRAW project (~170k lines):

- A qb64pe build is **two phases: (1) transpile** BASIC→C++ (the progress-bar phase), then
  **(2) g++** compile+link of the generated C++ (the "Compiling C++ code into executable…"
  phase — the bulk of the time).
- **Syntax / reserved-word / string-literal / arg-count errors are caught in phase 1.**
- **`-x` short-circuits at phase 1 on such errors — it never reaches g++.** VERIFIED: every
  failed `-x` build (`out` collision, `""` non-escape, `Foo$()` no-arg parens) produced NO
  "Compiling C++…" line; each aborted during transpile in ~1–2 min.
- Therefore a **failing `-x` ≈ a failing `-z`** (same phase, same time). `-z` gives **no**
  error-catching speed advantage. It only skips g++ on a **clean** compile (nothing to catch)
  and produces no binary — useful for a CI "does it fully transpile?" check, not iterative dev.
- **Recommendation:** for dev, just run `-x` — it fails as fast as `-z` on a syntax error AND
  yields a runnable binary on success. Don't add a `-z` pre-gate.

## [Linux] The real build-speed lever: skip C++ `-O` for dev builds

The multi-minute cost is g++ optimizing (a) QB64-PE's own runtime `internal/c/qbx.cpp` and
(b) the single giant generated `.cpp` from the whole program. Both are single compilation
units, so `-f:MaxCompilerProcesses` barely helps. What helps:

- **`-f:OptimizeCppProgram=false`** — skip `-O` for dev/test builds. On DRAW this cut a full
  build from **~13min → ~7min even while paying a one-time runtime rebuild** (warm-cache dev
  builds are faster still). Ship builds keep optimization on.
- **Flag consistency keeps the `qbx.o` runtime cache warm.** Changing `-f` flags between builds
  invalidates the cache and forces a full `qbx.cpp` recompile. Pick one dev flag set and stick
  to it so the runtime is compiled once and reused.

## ⚠️ `lib/lint.sh` fragment-mode Layer-A is unreliable

Given `projectEntry: DRAW.BAS`, Layer A runs `qb64pe -z $eflag -w -m -q DRAW.BAS`
(lib/lint.sh:28, target set :131-132). It reported a **spurious** `Invalid variable name …
T0 = _UPTIME` in the **untouched** `CORE/PERF.BM` that a plain `qb64pe -z DRAW.BAS` (no
`-w -m -q`) does NOT produce. Suspect the added flags. Until pinned down, prefer a plain
`qb64pe -z <entry>.BAS`, and distrust projectEntry Layer-A output that flags a file you did
not touch. Also: Layer B's "self-reference SIGSEGV" regex FALSE-flags every
`CASE x : FUNC$ = "..."` assignment (those are returns/LHS, not recursive reads/RHS).

## Idea: a real QB64-PE linter belongs INSIDE the compiler

The valuable checks (self-ref-read, reserved-word collisions, `AND`/`OR` non-short-circuit,
`NOT` bitwise, no-arg parens) are **semantic** — they need real name+type resolution, which
lives in the compiler's own parser/symbol table. An external regex tool has false positives
precisely because it lacks that. Two good paths, both avoiding a reimplemented parser:
1. Have the compiler **emit its AST/symbol table** (JSON) during `-z`; any tool (Rust, etc.)
   analyzes that with zero reparse and zero drift.
2. Add a native **`-l` lint** mode that runs the real front-end and walks the parsed tree.
A clean-room Rust+AST linter is the highest-effort path (you own a full QB64 parser forever,
which drifts from the real compiler). Curate the **rule catalog** first — it outlives any
engine choice — then pick 1 or 2.
