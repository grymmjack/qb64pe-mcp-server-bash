# qb64pe-mcp-server-bash

A lean QB64PE development MCP server built on the
[mcp-server-bash-sdk](https://github.com/muthuishere/mcp-server-bash-sdk) — pure `bash` + `jq`,
no Node, no build step. It is a focused rewrite of the 22k-line TypeScript `qb64pe-mcp-server`,
keeping only the capabilities that real usage (and a month of cross-model session-problem logs)
proved valuable, and fixing the things that were broken.

## Why this exists

Analysis of actual QB64PE/DRAW development sessions showed:

- **69% of all logged problems were syntax errors**, and the #1 time sink across Copilot/Claude/GPT
  was *not using the available tools first* — guessing QB64PE syntax instead of validating.
- The old server's **wiki tools dropped the Syntax/Parameters/Description sections** (so they were
  bypassed for WebFetch), and its **compile tool was banned** (false SIGTERM timeouts, sandbox-blocked
  `internal/temp` writes, stripped TTY error display).

This server addresses those directly:

1. **Native MCP `instructions`** tell the model to validate first and list the known QB64PE gotchas —
   replacing the old 200-line custom "tool discovery" subsystem for free.
2. **`wiki_page` returns the complete raw wikitext** (every section) via the MediaWiki API — no HTML
   scraping step to silently drop content.
3. **`lint` shells out to the compiler's fast `-z` syntax check** (authoritative, ~sub-second) plus
   regex rules for runtime-semantic traps the compiler accepts but that crash — most importantly the
   FUNCTION self-reference SIGSEGV.
4. **`compile` runs unsandboxed under a real pty** (`script`), with no artificial timeout — sidestepping
   every root cause of the old tool's failures.

## Tools

| Tool | What it does |
|------|--------------|
| `wiki_page` | Fetch the COMPLETE QB64PE wiki page (raw wikitext, all sections) for a keyword/topic. |
| `wiki_search` | Find matching pages. Primary index is the offline keyword DB (token/alias match — works for underscore + multi-word terms); the wiki full-text search is a best-effort supplement. |
| `keyword_lookup` | Fast offline lookup from the bundled 950-keyword DB (syntax, example, availability, wiki URL). |
| `lint` | Layer A: compiler `-z` syntax check. Layer B: regex rules (self-reference SIGSEGV, return-type sigil, reserved-word collisions, bare TRUE/FALSE, `DIM SHARED` in `.BM`, UDT returns, stray `DECLARE`, `NOT`-as-boolean, empty `_LOADIMAGE`). |
| `inject_logging` | Add `$CONSOLE`/`$CONSOLE:ONLY` + native `_LOG*` scaffolding for automated debugging (non-destructive by default). |
| `compile` | Headless pty compile, unsandboxed, no false timeout; returns full output + success inference. Accepts `source` or its alias `file`. |
| `run_and_screenshot` | **Safe default for automated verification:** launch → wait for the window → settle → capture a PNG → **guaranteed teardown** of the program (kills its whole process group on every exit path). No window is ever stranded. |
| `run` | Launch the built binary detached in its OWN process group (`setsid`); return PID + window id. Installs a 120s self-terminating backstop (override with `lifetimeSeconds`, `0` disables). |
| `stop` | Tear down a program launched by `run`, by the integer PID it returned — kills the whole process group (`SIGTERM`→`SIGKILL`). By-integer only, never by command-line match. Idempotent. |
| `screenshot` | Timing-correct window capture to a PNG. Liveness-checks the target before/at capture and rejects zero-byte (window-closed) captures (returns the path; read it with the Read tool). |
| `doctor` | Report this machine's cross-platform capabilities: detected OS (Linux/macOS/Windows, incl. WSL), compiler path, and whether the per-OS launch/teardown/window/capture pieces are present (with install hints). |

## Requirements

- `bash`, `jq` (always)
- `curl` — `wiki_page` / `wiki_search`
- `qb64pe` — `lint` (Layer A) / `compile`. Found via `$QB64PE_BIN`, then `PATH`, then common install dirs.
- GUI tools (`run` / `stop` / `run_and_screenshot` / `screenshot`) — per OS:
  - **Linux / WSL (X11):** `xdotool` + ImageMagick (`import`) or `scrot`; `setsid` (util-linux). WSL needs WSLg.
  - **macOS:** built-in `screencapture` + `osascript`; `perl` (for the `setsid` shim) or `brew install util-linux`.
  - **Windows (Git Bash / MSYS2):** built-in PowerShell + `taskkill` (no install). Run `doctor` to verify.

  Run the **`doctor`** tool to see exactly what's present/missing on the current machine.

> **In-program capture alternative:** for programs you control, QB64PE's built-in
> `_SAVEIMAGE filename$` writes a pixel-perfect frame from inside the program — no `_NET_WM_PID`,
> occlusion, or settle-timing concerns. It needs a source hook (e.g. a `--screenshot` dev flag after
> the first `_DISPLAY`); the X11 `run_and_screenshot` path is the no-recompile fallback for any binary.

## Install (Claude Code / `.mcp.json`)

```json
{
  "mcpServers": {
    "qb64pe": {
      "command": "/home/grymmjack/git/qb64pe-mcp-server-bash/qb64pe_mcp_server.sh",
      "env": {
        "QB64PE_BIN": "/home/grymmjack/git/qb64pe/qb64pe",
        "MCP_TOOL_TIMEOUT": "600000"
      }
    }
  }
}
```

> Set a generous `MCP_TOOL_TIMEOUT` (e.g. 600000 ms) so long project compiles are never cut off —
> that was the root cause of the old compile tool's false failures.

## Layout

```
qb64pe_mcp_server.sh     entry point (sets config paths, sources core + lib/*, starts the loop)
mcpserver_core.sh        vendored MCP protocol core — ONE patch: the newline-flatten line removed
assets/
  qb64pe_config.json     serverInfo + capabilities + the all-important `instructions` payload
  qb64pe_tools.json      tool manifest (JSON Schema input schemas)
lib/
  common.sh              compiler discovery + source materialization helpers
  platform.sh            OS abstraction (linux/macOS/windows): launch, teardown, window-resolve, capture, pty + tool_doctor
  docs.sh                wiki_page, wiki_search, keyword_lookup
  lint.sh                tool_lint (Layer A compiler + Layer B regex)
  selfref.awk            the FUNCTION self-reference (SIGSEGV) detector
  logging.sh             inject_logging (auto-detects GUI vs console programs)
  compile.sh             compile, run, stop, run_and_screenshot, screenshot (call the platform shims)
data/
  keywords.json          950-keyword offline database
  reserved-words.txt     256 reserved words (for the collision rule)
test/
  test_qb64pe_server.sh  complete black-box harness — all 11 tools over JSON-RPC, 1:1 with the client
```

## Vendored core patch

The SDK core flattens newlines (`tr '\n' ' '`) before stringifying tool output, which destroys
code/doc formatting. The vendored copy here removes that one line; the subsequent `jq -R -s '.'`
already escapes newlines correctly, so multi-line wiki docs and code are preserved.

## Cross-platform

The docs/lint/compile tools are OS-agnostic. The GUI tools (`run`/`stop`/`run_and_screenshot`/`screenshot`)
and the compile pty are abstracted behind `lib/platform.sh`, which dispatches on `_qb_os`:

| | Linux / WSL | macOS | Windows (Git Bash/MSYS2) |
|---|---|---|---|
| launch (own group) | `setsid` | `setsid` or `perl` shim | background `.exe` + winpid |
| teardown | `kill -<pgid>` | `kill -<pgid>` | `taskkill /T /F` |
| find window | snapshot-diff `xdotool` (no `_NET_WM_PID`) | `osascript` (by unix id) | `Get-Process … MainWindowHandle` |
| capture | `import`/`scrot` | `screencapture` (region) | PowerShell `CopyFromScreen` |
| pty compile | `script -qefc` | `script -q` | `script` or direct exec |

**Validation status:** Linux/X11 is the tested reference (the harness exercises it live). macOS and
Windows paths are implemented with the native commands above but are marked **VALIDATE-ON-DEVICE** in
the source until run on real hardware — `doctor` reports what's present, and each shim emits a clear
"missing X" message rather than failing silently.

## Testing

```bash
./test/test_qb64pe_server.sh        # complete harness — all 11 tools, black-box over JSON-RPC
```

The harness drives the **real server over JSON-RPC, 1:1 with the MCP client**: it reads the `env`
block (`QB64PE_BIN`) from the project's `.mcp.json` and exports it, and gates the compiler tests using
the server's own `_qb_find_compiler`. Environment-dependent tests (compiler / network / X11) print
`○ SKIP: <reason>` instead of failing, so it's honest on headless CI. The P1 teardown contract
(`setsid` own-PGID → kill by integer) is unit-tested portably against `sleep`, and the live path
compiles a tiny `SCREEN _NEWIMAGE` program and runs `run_and_screenshot` against a real X window.
A `trap cleanup EXIT` kills every launched process group so the harness never strands a window.

Baseline in a full environment (compiler + network + X11): **78 passed, 0 failed, 0 skipped**.
Override the config path with `QB64PE_MCP_JSON=/path/to/.mcp.json`.
