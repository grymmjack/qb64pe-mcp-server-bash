#!/bin/bash
# test_qb64pe_server.sh — COMPLETE tool harness for the QB64PE bash MCP server.
#
# Black-box: pipes JSON-RPC requests to the server on stdin and asserts on the
# responses (so it covers the real protocol/stringification path too). Tests that
# need an external dependency (QB64PE compiler, network, X11) are gated and SKIPPED
# with a printed reason rather than failing — run it anywhere, headless CI included.
#
# Coverage: protocol (initialize, tools/list) + all 10 tools —
#   wiki_page, wiki_search, keyword_lookup, lint, inject_logging,
#   compile, run, stop, run_and_screenshot, screenshot.
# The P1 teardown contract (setsid own-PGID + kill-by-integer) is unit-tested
# portably against `sleep`, so it runs even with no compiler/display.
#
# Exit code: non-zero iff a real assertion FAILED (skips never fail the run).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/../qb64pe_mcp_server.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      got: $2"; FAIL=$((FAIL+1)); }
skip() { echo "  ○ SKIP: $1"; SKIP=$((SKIP+1)); }
section() { echo; echo "== $1 =="; }

# --- Never strand a launched process: kill tracked groups on any exit ----------
TRACKED=()
track_pid() { [[ "$1" =~ ^[0-9]+$ ]] && TRACKED+=("$1"); }
cleanup() {
    local p
    for p in "${TRACKED[@]}"; do
        kill -TERM "-$p" 2>/dev/null; kill -KILL "-$p" 2>/dev/null
        kill -TERM  "$p" 2>/dev/null; kill -KILL  "$p" 2>/dev/null
    done
}
trap cleanup EXIT INT TERM

# --- request helpers -----------------------------------------------------------
send_raw()       { printf '%s\n' "$1" | "$SERVER" 2>/dev/null; }
send_nodisplay() { printf '%s\n' "$1" | env -u DISPLAY "$SERVER" 2>/dev/null; }
mkreq() { jq -nc --arg n "$1" --argjson a "$2" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$n,arguments:$a}}'; }
# call_text <tool> <argsJson>  -> .result.content[0].text (or .error.message)
call_text()     { send_raw       "$(mkreq "$1" "$2")" | jq -r '.result.content[0].text // .error.message // "NO_RESULT"'; }
call_text_nox() { send_nodisplay "$(mkreq "$1" "$2")" | jq -r '.result.content[0].text // .error.message // "NO_RESULT"'; }
assert_contains()  { [[ "$1" == *"$2"* ]] && ok "$3" || bad "$3" "$1"; }
assert_excludes()  { [[ "$1" != *"$2"* ]] && ok "$3" || bad "$3" "$1"; }

# --- Launch the server EXACTLY as the MCP client does --------------------------
# Load the server's `env` block from the project's .mcp.json and export it, so the
# server resolves QB64PE_BIN (and anything else) identically to the real client.
# Override the config location with QB64PE_MCP_JSON=... if needed.
MCP_JSON="${QB64PE_MCP_JSON:-}"
if [[ -z "$MCP_JSON" ]]; then
    for c in /home/grymmjack/git/DRAW/.mcp.json "$SCRIPT_DIR/../.mcp.json" "$HOME/git/DRAW/.mcp.json"; do
        [[ -f "$c" ]] && { MCP_JSON="$c"; break; }
    done
fi
if [[ -n "$MCP_JSON" && -f "$MCP_JSON" ]]; then
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        export "$k=$v"
    done < <(jq -r '
        .mcpServers | to_entries[]
        | select((.value.command // "") | test("qb64pe_mcp_server\\.sh$"))
        | (.value.env // {}) | to_entries[] | "\(.key)\t\(.value)"' "$MCP_JSON" 2>/dev/null)
fi

# --- Detect deps the SAME way the server does (reuse its own resolver) ----------
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/common.sh"   # provides _qb_find_compiler (honors QB64PE_BIN)
COMPILER="$(_qb_find_compiler)"
HAVE_XDOTOOL=0; command -v xdotool &>/dev/null && HAVE_XDOTOOL=1
HAVE_IMPORT=0;  { command -v import &>/dev/null || command -v scrot &>/dev/null; } && HAVE_IMPORT=1
HAVE_DISPLAY=0; [[ -n "$DISPLAY" ]] && HAVE_DISPLAY=1
HAVE_NET=0;     curl -sS --max-time 4 -o /dev/null "https://qb64phoenix.com/qb64wiki/api.php?format=json&action=query&meta=siteinfo" 2>/dev/null && HAVE_NET=1
SLEEP_BIN="$(command -v sleep)"

echo "qb64pe-mcp-server-bash — complete tool harness"
echo "env: compiler=$([[ -n $COMPILER ]] && echo yes || echo no)  display=$([[ $HAVE_DISPLAY == 1 ]] && echo yes || echo no)  xdotool=$([[ $HAVE_XDOTOOL == 1 ]] && echo yes || echo no)  screenshot-backend=$([[ $HAVE_IMPORT == 1 ]] && echo yes || echo no)  network=$([[ $HAVE_NET == 1 ]] && echo yes || echo no)"

# ==============================================================================
section "protocol: initialize"
INIT=$(send_raw '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')
assert_contains "$INIT" '"serverInfo"'           "initialize returns serverInfo"
assert_contains "$INIT" 'USE THESE TOOLS FIRST'  "initialize surfaces validate-first instructions"
assert_contains "$INIT" 'RECURSIVE CALL'         "instructions include the self-reference gotcha"
assert_contains "$INIT" 'run_and_screenshot'     "instructions mention the safe capture loop"

section "protocol: tools/list (11 tools)"
LIST=$(send_raw '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
N=$(echo "$LIST" | jq -r '.result.tools | length')
[[ "$N" == "11" ]] && ok "tools/list returns 11 tools" || bad "tools/list returns 11 tools" "got $N"
for t in wiki_page wiki_search keyword_lookup lint inject_logging compile run stop run_and_screenshot screenshot doctor; do
    assert_contains "$LIST" "\"$t\"" "manifest includes $t"
done

# ==============================================================================
section "keyword_lookup (offline)"
KW=$(call_text keyword_lookup '{"keyword":"_PUTIMAGE"}')
assert_contains "$KW" "_PUTIMAGE" "keyword_lookup finds _PUTIMAGE"
assert_contains "$KW" "Syntax:"   "keyword_lookup includes Syntax section"
KWMISS=$(call_text keyword_lookup '{"keyword":"ZZ_NOPE_QQ"}')
assert_contains "$KWMISS" "No exact match" "keyword_lookup reports a clean miss"

# ==============================================================================
section "wiki_search (OFFLINE keyword-DB path — regression guard for the search-index bug)"
# These three all returned 'No wiki results' under the old remote-only search.
WS1=$(call_text wiki_search '{"query":"_MOUSEBUTTON"}')
assert_contains "$WS1" "_MOUSEBUTTON" "wiki_search finds underscore keyword _MOUSEBUTTON"
WS2=$(call_text wiki_search '{"query":"mouse input"}')
assert_contains "$WS2" "_MOUSEINPUT"  "wiki_search resolves multi-word 'mouse input' -> _MOUSEINPUT"
WS3=$(call_text wiki_search '{"query":"alpha transparency"}')
assert_contains "$WS3" "_SETALPHA"    "wiki_search resolves 'alpha transparency' -> _SETALPHA"
assert_contains "$WS3" "offline keyword database" "wiki_search labels the offline section"
WS4=$(call_text wiki_search '{"query":"load image"}')
assert_contains "$WS4" "_LOADIMAGE"   "wiki_search resolves 'load image' -> _LOADIMAGE"
WSMISS=$(call_text wiki_search '{"query":"zzqqxx_nonsense_token"}')
assert_contains "$WSMISS" "No results" "wiki_search reports a clean miss for nonsense"
WSNOQ=$(call_text wiki_search '{}')
assert_contains "$WSNOQ" "Missing required parameter" "wiki_search requires a query"

# ==============================================================================
section "wiki_page / wiki_search remote (network-gated)"
if [[ "$HAVE_NET" == 1 ]]; then
    WP=$(call_text wiki_page '{"page":"_PUTIMAGE"}')
    assert_contains "$WP" "_PUTIMAGE" "wiki_page fetches _PUTIMAGE wikitext"
    assert_contains "$WP" "qb64phoenix.com" "wiki_page includes the page URL"
    WPMISS=$(call_text wiki_page '{"page":"Zzz_No_Such_Page_Qq"}')
    assert_contains "$WPMISS" "No wiki page found" "wiki_page reports a missing page cleanly"
else
    skip "no network — wiki_page/remote wiki_search not exercised (offline wiki_search still verified above)"
fi

# ==============================================================================
section "lint — Layer B regex rules (instant, no compiler)"
read -r -d '' CODE <<'EOF'
FUNCTION Cur%
    DIM r AS INTEGER
    r = 5
    IF Cur% < 0 THEN r = 0
    Cur% = r
END FUNCTION

DECLARE SUB Foo
DIM pos AS INTEGER
FUNCTION Bar() AS INTEGER
EOF
LARGS=$(jq -nc --arg c "$CODE" '{code:$c, syntaxCheck:false}')
LINT=$(call_text lint "$LARGS")
assert_contains "$LINT" "SKIPPED (syntaxCheck=false)" "syntaxCheck:false truly skips the compiler (jq // false guard)"
assert_contains "$LINT" "self-reference" "lint flags the FUNCTION self-reference (SIGSEGV)"
assert_contains "$LINT" "declare"        "lint flags stray DECLARE SUB"
assert_contains "$LINT" "reserved-word"  "lint flags reserved-word var 'pos'"
assert_contains "$LINT" "return-type"    "lint flags FUNCTION ... AS INTEGER"

section "lint — clean code has no false self-reference"
read -r -d '' CLEAN <<'EOF'
FUNCTION Cur%
    DIM r AS INTEGER
    r = 5
    IF r < 0 THEN r = 0
    Cur% = r
END FUNCTION
EOF
CARGS=$(jq -nc --arg c "$CLEAN" '{code:$c, syntaxCheck:false}')
CLEANOUT=$(call_text lint "$CARGS")
assert_excludes "$CLEANOUT" "self-reference" "clean code has no self-reference finding"

section "lint — Layer A compiler -z (compiler-gated)"
if [[ -n "$COMPILER" ]]; then
    LA=$(call_text lint "$(jq -nc --arg c "$CLEAN" '{code:$c, syntaxCheck:true}')")
    assert_contains "$LA" "Syntax (compiler -z):" "lint runs the compiler -z layer"
    assert_excludes "$LA" "SKIPPED (syntaxCheck=false)" "Layer A actually ran (not skipped)"
else
    skip "no QB64PE compiler — Layer A (-z) not exercised (set QB64PE_BIN to enable)"
fi

# ==============================================================================
section "inject_logging (non-destructive, multi-line preserved)"
IL=$(call_text inject_logging "$(jq -nc '{code:"PRINT \"hi\"", mode:"console"}')")
assert_contains "$IL" '$CONSOLE:ONLY' "inject_logging adds \$CONSOLE:ONLY"
assert_contains "$IL" '_LOGINFO'      "inject_logging adds _LOGINFO banner"
assert_contains "$IL" 'NOT modified'  "inject_logging is non-destructive by default"
ILG=$(call_text inject_logging "$(jq -nc '{code:"SCREEN _NEWIMAGE(320,200,32)", mode:"graphics"}')")
assert_contains "$ILG" '$CONSOLE'     "graphics mode uses \$CONSOLE (window still opens)"
assert_excludes "$ILG" ':ONLY'        "graphics mode does NOT use \$CONSOLE:ONLY"
# auto mode (the new default): GUI program must NOT get $CONSOLE:ONLY (would hide the window)
ILA_GFX=$(call_text inject_logging "$(jq -nc '{code:"SCREEN _NEWIMAGE(640,480,32)\n_DISPLAY"}')")
assert_contains "$ILA_GFX" '$CONSOLE' "auto keeps \$CONSOLE for a graphics (GUI) program"
assert_excludes "$ILA_GFX" ':ONLY'    "auto does NOT suppress a GUI program's window"
# auto mode: pure text program is fine with console-only
ILA_TXT=$(call_text inject_logging "$(jq -nc '{code:"PRINT \"hello\"\nINPUT x"}')")
assert_contains "$ILA_TXT" '$CONSOLE:ONLY' "auto uses \$CONSOLE:ONLY for a text-only program"
# explicit console on a graphical source must WARN (don't silently hide DRAW's window)
ILW=$(call_text inject_logging "$(jq -nc '{code:"SCREEN _NEWIMAGE(320,200,32)", mode:"console"}')")
assert_contains "$ILW" 'WARNING' "explicit console on a GUI source warns about window suppression"

# ==============================================================================
section "compile — parameter handling (file alias, ungated)"
CMISS=$(call_text compile '{}')
assert_contains "$CMISS" "Missing required parameter" "compile with no source/file errors clearly"
# 'file' alias must resolve to the path (proven by a file-not-found, NOT a missing-param, error)
CALIAS=$(call_text compile '{"file":"/nonexistent/zzz.bas"}')
assert_contains "$CALIAS" "Source file not found"     "compile accepts 'file' as alias for 'source'"
assert_excludes "$CALIAS" "Missing required parameter" "file alias is not treated as a missing param"
# output-path/directory collision (the ld 'Is a directory' trap) -> clear early error
CDWD=$(mktemp -d); echo 'PRINT 1' > "$CDWD/qbtest.bas"; mkdir -p "$CDWD/qbtest"
CDIR=$(call_text compile "$(jq -nc --arg s "$CDWD/qbtest.bas" '{source:$s}')")
assert_contains "$CDIR" "Output path is a directory"  "compile catches an output-path/directory collision early"
assert_excludes "$CDIR" "=== QB64PE compile ==="      "compile short-circuits before invoking the compiler (clear error, no linker run)"
rm -rf "$CDWD"

section "compile — real build (compiler-gated)"
if [[ -n "$COMPILER" ]]; then
    WD=$(mktemp -d)
    cat > "$WD/hello.bas" <<'EOF'
PRINT Add%(2, 3)
FUNCTION Add% (a AS INTEGER, b AS INTEGER)
    Add% = a + b
END FUNCTION
EOF
    CB=$(call_text compile "$(jq -nc --arg s "$WD/hello.bas" '{source:$s}')")
    assert_contains "$CB" "success : yes" "compile builds a tiny valid program"
    [[ -f "$WD/hello" ]] && ok "compile produced the output binary" || bad "compile produced the output binary" "no $WD/hello"
    rm -rf "$WD"
else
    skip "no QB64PE compiler — real compile not exercised"
fi

# ==============================================================================
section "run + stop — teardown contract (setsid own-PGID, kill by integer)"
if [[ -n "$SLEEP_BIN" ]]; then
    RT=$(call_text_nox run "$(jq -nc --arg b "$SLEEP_BIN" '{binary:$b, args:"300", lifetimeSeconds:0}')")
    PID=$(grep -oE 'pid[[:space:]]*:[[:space:]]*[0-9]+' <<<"$RT" | grep -oE '[0-9]+' | head -1)
    track_pid "$PID"
    if [[ "$PID" =~ ^[0-9]+$ ]]; then
        ok "run returns an integer pid ($PID)"
        kill -0 "$PID" 2>/dev/null && ok "launched process is alive" || bad "launched process is alive" "pid $PID not running"
        PGID=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')
        [[ "$PGID" == "$PID" ]] && ok "setsid made the process its own group leader (PGID==PID)" \
            || bad "PGID==PID (own process group)" "pgid=$PGID pid=$PID"
        assert_contains "$RT" "backstop : DISABLED" "lifetimeSeconds:0 disables the auto-stop backstop"
        ST=$(call_text stop "$(jq -nc --argjson p "$PID" '{pid:$p}')")
        assert_contains "$ST" "Stopped process group" "stop tears the program down"
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && bad "process is dead after stop" "pid $PID still alive" \
            || ok "process is dead after stop"
        ST2=$(call_text stop "$(jq -nc --argjson p "$PID" '{pid:$p}')")
        assert_contains "$ST2" "No live process" "stop is idempotent (already-stopped is clean)"
    else
        bad "run returns an integer pid" "$RT"
    fi
else
    skip "no 'sleep' binary — teardown contract not exercised (unexpected)"
fi

section "run — auto-stop backstop fires (lifetimeSeconds)"
if [[ -n "$SLEEP_BIN" ]]; then
    RT2=$(call_text_nox run "$(jq -nc --arg b "$SLEEP_BIN" '{binary:$b, args:"300", lifetimeSeconds:2}')")
    PID2=$(grep -oE 'pid[[:space:]]*:[[:space:]]*[0-9]+' <<<"$RT2" | grep -oE '[0-9]+' | head -1)
    track_pid "$PID2"
    assert_contains "$RT2" "auto-stops process group after 2s" "run reports the 2s backstop"
    if [[ "$PID2" =~ ^[0-9]+$ ]]; then
        kill -0 "$PID2" 2>/dev/null && ok "backstopped process is alive immediately after launch" \
            || bad "backstopped process alive at launch" "pid $PID2 not running"
        # Wait for the backstop (2s + grace) to fire.
        dead=0
        for _ in $(seq 1 12); do sleep 0.5; kill -0 "$PID2" 2>/dev/null || { dead=1; break; }; done
        [[ "$dead" == 1 ]] && ok "backstop auto-stopped the process group within its lifetime" \
            || bad "backstop auto-stops the process" "pid $PID2 still alive after ~6s"
    fi
else
    skip "no 'sleep' binary — backstop not exercised"
fi

section "stop — error paths"
assert_contains "$(call_text stop '{}')"            "Missing required parameter" "stop requires a pid"
assert_contains "$(call_text stop '{"pid":"abc"}')" "Invalid pid"                "stop rejects a non-integer pid"
assert_contains "$(call_text stop '{"pid":2147480000}')" "No live process"       "stop on a dead pid is clean"

# ==============================================================================
section "run_and_screenshot / screenshot — input guards (ungated)"
assert_contains "$(call_text run_and_screenshot '{}')" "Missing required parameter: binary" "run_and_screenshot requires a binary"
RAS_NOBIN=$(call_text run_and_screenshot "$(jq -nc '{binary:"/nonexistent/zz"}')")
assert_contains "$RAS_NOBIN" "not found or not executable" "run_and_screenshot validates the binary path"
SS_NODISP=$(call_text_nox screenshot '{"window":"anything"}')
assert_contains "$SS_NODISP" "DISPLAY is unset" "screenshot guards on an unset DISPLAY"

# ==============================================================================
section "run_and_screenshot — LIVE capture + guaranteed teardown (compiler+X11-gated)"
if [[ -n "$COMPILER" && "$HAVE_DISPLAY" == 1 && "$HAVE_XDOTOOL" == 1 && "$HAVE_IMPORT" == 1 ]]; then
    WD=$(mktemp -d)
    cat > "$WD/win.bas" <<'EOF'
SCREEN _NEWIMAGE(320, 200, 32)
_TITLE "qbtest-harness-window"
DO
    CLS
    LINE (20, 20)-(140, 120), _RGB32(220, 40, 40), BF
    _DISPLAY
    _LIMIT 30
LOOP
EOF
    CBUILD=$(call_text compile "$(jq -nc --arg s "$WD/win.bas" '{source:$s}')")
    if [[ "$CBUILD" == *"success : yes"* && -f "$WD/win" ]]; then
        PNG="$WD/shot.png"
        RAS=$(call_text run_and_screenshot "$(jq -nc --arg b "$WD/win" --arg o "$PNG" '{binary:$b, output:$o, maxWaitSeconds:8}')")
        assert_contains "$RAS" "Screenshot saved" "run_and_screenshot captured a live QB64PE window"
        [[ -s "$PNG" ]] && ok "saved PNG is non-empty" || bad "saved PNG is non-empty" "$RAS"
        # Guaranteed teardown: the pid it reports must be dead.
        RPID=$(grep -oE 'pid \(now stopped\): [0-9]+' <<<"$RAS" | grep -oE '[0-9]+' | head -1)
        track_pid "$RPID"
        if [[ "$RPID" =~ ^[0-9]+$ ]]; then
            sleep 0.4
            kill -0 "$RPID" 2>/dev/null && bad "run_and_screenshot tore the program down" "pid $RPID still alive" \
                || ok "run_and_screenshot guaranteed teardown (process group dead)"
        fi
    else
        bad "compile the live-window test program" "$CBUILD"
    fi
    rm -rf "$WD"
else
    skip "needs compiler + DISPLAY + xdotool + screenshot backend — live capture not exercised"
fi

# ==============================================================================
section "doctor + platform abstraction (cross-platform)"
DOC=$(call_text doctor '{}')
assert_contains "$DOC" "platform capabilities" "doctor returns a capability report"
assert_contains "$DOC" "OS class"              "doctor reports the detected OS class"
assert_contains "$DOC" "QB64PE compiler"       "doctor reports compiler availability"
# White-box: the platform helpers detect this OS consistently with the server.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/platform.sh"
OSCLS=$(_qb_os)
assert_contains "linux macos windows" "$OSCLS" "_qb_os returns a known OS class ($OSCLS)"
if [[ "$OSCLS" == windows ]]; then
    [[ "$(_qb_exe_suffix)" == ".exe" ]] && ok "exe suffix is .exe on windows" || bad "exe suffix .exe" "got '$(_qb_exe_suffix)'"
else
    [[ -z "$(_qb_exe_suffix)" ]] && ok "exe suffix empty on $OSCLS" || bad "exe suffix empty on $OSCLS" "got '$(_qb_exe_suffix)'"
fi
# The whole platform contract is present (catches a typo'd/renamed shim).
PLAT_OK=1
for fn in _qb_os _qb_exe_suffix _qb_launch _qb_kill_group _qb_pid_alive _qb_window_list \
          _qb_resolve_window _qb_window_alive _qb_capture_window _qb_gui_ready _qb_pty_compile; do
    type "$fn" &>/dev/null || { PLAT_OK=0; echo "      missing shim: $fn"; }
done
[[ "$PLAT_OK" == 1 ]] && ok "all platform shims are defined" || bad "all platform shims are defined" "see above"

# ==============================================================================
echo
echo "================  $PASS passed, $FAIL failed, $SKIP skipped  ================"
[[ "$FAIL" -eq 0 ]]
