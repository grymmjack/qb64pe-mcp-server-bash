#!/bin/bash
# compile.sh — tool_compile / tool_run / tool_screenshot.
# Redesign of the old (banned) compile tool: runs unsandboxed (no internal/temp block),
# under a real pty via `script` (fixes the stdin-EOF bail + preserves QB64PE's TTY error
# display), with NO artificial timeout. Takes explicit flags only (no stored-context merge,
# which caused the logged doubled-`-o` failure).

# Process-management, window-resolution, capture and pty helpers now live in
# lib/platform.sh (the OS abstraction): _qb_launch, _qb_kill_group,
# _qb_window_list, _qb_resolve_window, _qb_capture_window, _qb_window_alive,
# _qb_gui_ready, _qb_exe_suffix, _qb_pty_compile. The tools below call those so a
# single body serves Linux/macOS/Windows.

# tool_compile — headless compile of a .BAS.
tool_compile() {
    local args="$1"
    local source output maxp purge extra
    # Accept 'file' as an alias for 'source' so the path param is uniform with
    # lint/inject_logging (which use 'file'). 'source' wins if both are given.
    source=$(echo "$args" | jq -r '.source // .file // empty')
    output=$(echo "$args" | jq -r '.output // empty')
    maxp=$(echo "$args" | jq -r '.maxProcesses // 8')
    purge=$(echo "$args" | jq -r '.purge // false')
    extra=$(echo "$args" | jq -r '.extraFlags // empty')

    [[ -z "$source" ]] && { echo "Missing required parameter: source (or its alias 'file')"; return 1; }
    [[ ! -f "$source" ]] && { echo "Source file not found: $source"; return 1; }
    [[ "$maxp" =~ ^[0-9]+$ ]] || maxp=8

    # Output path (also used below for success inference). Validate it BEFORE we
    # spend a compiler run: the compiler links the executable to this path, so a
    # directory sitting there yields a cryptic, mid-toolchain
    # "ld: cannot open output file ...: Is a directory". Catch it here with a
    # clear, actionable message instead.
    local expected
    if [[ -n "$output" ]]; then expected="$output"; else expected="${source%.*}$(_qb_exe_suffix)"; fi
    if [[ -d "$expected" ]]; then
        echo "Output path is a directory, not a file: $expected"
        echo "Pass an explicit 'output' file path, or clear/rename that directory."
        echo "(A directory at the link target makes the linker fail with 'cannot open output file ...: Is a directory'.)"
        return 1
    fi

    local comp; comp=$(_qb_find_compiler)
    [[ -z "$comp" ]] && { echo "QB64PE compiler not found. Set QB64PE_BIN."; return 1; }

    # The pty wrapper (`script`) is needed on Linux/macOS; Windows/MSYS falls back
    # to a direct run inside _qb_pty_compile, so don't hard-require it there.
    if [[ "$(_qb_os)" != windows ]] && ! command -v script &>/dev/null; then
        echo "'script' (util-linux) is required for pty-based compilation."
        return 1
    fi

    local srcdir; srcdir=$(cd "$(dirname "$source")" && pwd)
    local srcbase; srcbase=$(basename "$source")

    # Build the compiler command, quoting paths safely for `script -c`.
    local cmd
    cmd=$(printf '%q -w -x -m -f:MaxCompilerProcesses=%q' "$comp" "$maxp")
    [[ "$purge" == "true" ]] && cmd+=" -p"
    [[ -n "$extra" ]] && cmd+=" $extra"
    cmd+=$(printf ' %q' "$srcbase")
    [[ -n "$output" ]] && cmd+=$(printf ' -o %q' "$output")

    # Pre-mtime of expected output (to detect a fresh build).
    local pre_mtime=0
    [[ -f "$expected" ]] && pre_mtime=$(stat -c %Y "$expected" 2>/dev/null || echo 0)

    local start_ts out crc
    start_ts=$(date +%s)
    # Run under a real pty (preserves QB64PE's TTY error display); dispatched per OS.
    out=$(_qb_pty_compile "$srcdir" "$cmd"); crc=$?
    local elapsed=$(( $(date +%s) - start_ts ))

    local post_mtime=0
    [[ -f "$expected" ]] && post_mtime=$(stat -c %Y "$expected" 2>/dev/null || echo 0)

    local success="no"
    if [[ -f "$expected" && ( "$post_mtime" -gt "$pre_mtime" || "$crc" -eq 0 ) ]]; then
        success="yes"
    fi

    # Clean the pty output: drop CRs, ANSI CSI escapes, and the noisy progress bar.
    out=$(printf '%s' "$out" \
        | tr -d '\r' \
        | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | grep -vE '^\[[.[:space:]]*\][[:space:]]*[0-9]+%[[:space:]]*$')

    echo "=== QB64PE compile ==="
    echo "command : (cd $srcdir && $cmd)"
    echo "exit    : $crc"
    echo "elapsed : ${elapsed}s"
    echo "output  : $expected $( [[ -f "$expected" ]] && echo '(exists)' || echo '(MISSING)')"
    echo "success : $success"
    echo "------------------------------------------------------------"
    echo "$out"
    [[ "$success" == "yes" ]] && return 0 || return 0   # report status in body; never hard-fail the call
}

# tool_run — launch the compiled binary detached; return PID + window id, and
# install a self-terminating backstop so an automated caller can never strand a
# window. Prefer 'run_and_screenshot' for the capture-then-teardown loop.
tool_run() {
    local args="$1"
    local binary rargs lifetime window
    binary=$(echo "$args" | jq -r '.binary // empty')
    rargs=$(echo "$args" | jq -r '.args // empty')
    window=$(echo "$args" | jq -r '.window // empty')
    # Backstop lifetime in seconds. Default 120; pass 0 to disable.
    lifetime=$(echo "$args" | jq -r '.lifetimeSeconds // 120')
    [[ "$lifetime" =~ ^[0-9]+$ ]] || lifetime=120

    [[ -z "$binary" ]] && { echo "Missing required parameter: binary"; return 1; }
    [[ ! -x "$binary" ]] && { echo "Binary not found or not executable: $binary"; return 1; }
    [[ "$(_qb_os)" == linux && -z "$DISPLAY" ]] && echo "(warning: DISPLAY is unset — a graphics window may not appear; under WSL use WSLg)"

    # Snapshot windows BEFORE launch so we can identify the one that appears
    # (QB64PE/SDL2 windows don't set _NET_WM_PID, so search-by-pid is unreliable).
    local snap; snap=$(_qb_window_list)
    local pid
    pid=$(_qb_launch "$binary" "$rargs")
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Failed to launch: $binary"; return 1; }

    # Backstop: a detached watcher that kills the process group after $lifetime.
    # It lives in the SERVER's group (not the binary's), so killing -$pid never
    # touches it; redirecting its stdout to /dev/null keeps the tool call from
    # blocking on it. This is what guarantees the window can't outlive its leash.
    if [[ "$lifetime" -gt 0 ]]; then
        { sleep "$lifetime"; _qb_kill_group "$pid"; } >/dev/null 2>&1 &
        disown 2>/dev/null
    fi

    # Resolve the window that appeared (an explicit _TITLE hint wins if given).
    local winid; winid=$(_qb_resolve_window "$pid" "$window" "$snap" 30)

    echo "Launched: $binary ${rargs}"
    echo "pid      : $pid"
    if [[ "$lifetime" -gt 0 ]]; then
        echo "backstop : auto-stops process group after ${lifetime}s (pass lifetimeSeconds:0 to disable)"
    else
        echo "backstop : DISABLED — you must call stop {\"pid\":$pid} or the window will linger"
    fi
    if [[ -n "$winid" ]]; then
        echo "windowId : $winid"
        echo "(screenshot {\"window\":$winid}, then stop {\"pid\":$pid} to tear down)"
    else
        echo "windowId : no new window appeared within timeout (console-only program, or a slow splash)."
        echo "If it has a window, pass its _TITLE: screenshot {\"window\":\"<title text>\"}."
        echo "Tear down with: stop {\"pid\":$pid}."
    fi
    return 0
}

# tool_stop — tear down a program launched by 'run', by its PID/PGID. Kills by
# integer only (never by command-line match). Idempotent.
tool_stop() {
    local args="$1"
    local pid
    pid=$(echo "$args" | jq -r '.pid // empty')
    [[ -z "$pid" ]] && { echo "Missing required parameter: pid"; return 1; }
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Invalid pid (must be the integer PID returned by 'run'): $pid"; return 1; }

    if ! _qb_pid_alive "$pid"; then
        echo "No live process or group for pid $pid (already stopped or never ran)."
        return 0
    fi

    _qb_kill_group "$pid"

    if _qb_pid_alive "$pid"; then
        echo "Signalled process group $pid (SIGTERM→SIGKILL); it may still be terminating."
    else
        echo "Stopped process group $pid."
    fi
    return 0
}

# tool_run_and_screenshot — the safe combined loop for automated callers:
# launch → wait for the window → settle → capture → GUARANTEED teardown.
# A RETURN trap kills the process group however the function exits (success,
# error, no-window, closed-mid-capture), so no window is ever stranded. All the
# blocking external calls are wrapped in `timeout` so the function can't wedge.
tool_run_and_screenshot() {
    local args="$1"
    local binary rargs window output delay maxwait
    binary=$(echo "$args" | jq -r '.binary // empty')
    rargs=$(echo "$args" | jq -r '.args // empty')
    window=$(echo "$args" | jq -r '.window // empty')
    output=$(echo "$args" | jq -r '.output // empty')
    delay=$(echo "$args" | jq -r '.delay // 1.5')
    maxwait=$(echo "$args" | jq -r '.maxWaitSeconds // 10')

    [[ -z "$binary" ]] && { echo "Missing required parameter: binary"; return 1; }
    [[ ! -x "$binary" ]] && { echo "Binary not found or not executable: $binary"; return 1; }
    local gerr; if ! gerr=$(_qb_gui_ready); then echo "$gerr"; return 1; fi
    # Floor the settle delay at 1.0s (DRAW idles ~15 FPS; racing a frame = stale).
    awk "BEGIN{ exit !($delay >= 1.0) }" 2>/dev/null || delay=1.5
    [[ "$maxwait" =~ ^[0-9]+$ ]] || maxwait=10

    if [[ -z "$output" ]]; then
        output="${TMPDIR:-/tmp}/qb64pe-shot-$(date +%Y%m%d-%H%M%S)-$$.png"
    fi

    # Snapshot windows BEFORE launch to identify the one that appears (QB64PE/SDL2
    # windows don't set _NET_WM_PID, so search-by-pid can't find them).
    local snap; snap=$(_qb_window_list)
    local pid
    pid=$(_qb_launch "$binary" "$rargs")
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Failed to launch: $binary"; return 1; }

    # From here on, guarantee teardown on EVERY exit path.
    trap '_qb_kill_group "$pid" 2>/dev/null' RETURN

    # Resolve the window that appeared (an explicit _TITLE hint wins if given).
    local winid; winid=$(_qb_resolve_window "$pid" "$window" "$snap" $(( maxwait * 5 )))

    if [[ -z "$winid" ]]; then
        echo "Launched pid $pid but no window appeared within ${maxwait}s."
        echo "(Console-only program, or it set a _TITLE — retry with window:\"<title>\".)"
        echo "Process group $pid has been stopped."
        return 0   # RETURN trap kills the group
    fi

    # Activate → settle → liveness-check → capture, dispatched per OS.
    _qb_capture_window "$winid" "$pid" "$output" "$delay"
    case "$?" in
        0)  echo "Screenshot saved: $output"
            echo "pid (now stopped): $pid"
            echo "(Read this file with the Read tool to view it. Compare visible content, not file size.)" ;;
        2)  echo "Window closed before capture (program exited or was closed)."
            echo "Process group $pid has been stopped." ;;
        3)  echo "No screenshot backend available for this OS."
            echo "Process group $pid has been stopped." ;;
        *)  [[ -f "$output" ]] && rm -f "$output"
            echo "Capture produced no/zero-byte image — window likely closed mid-capture. No screenshot saved."
            echo "Process group $pid has been stopped." ;;
    esac
    return 0
}

# tool_screenshot — timing-correct capture to a PNG; return the path.
tool_screenshot() {
    local args="$1"
    local window output delay
    window=$(echo "$args" | jq -r '.window // empty')
    output=$(echo "$args" | jq -r '.output // empty')
    delay=$(echo "$args" | jq -r '.delay // 1.5')

    local gerr; if ! gerr=$(_qb_gui_ready); then echo "$gerr"; return 1; fi
    # numeric delay floor of 1.0 (DRAW idles ~15 FPS; racing the frame gives stale captures)
    awk "BEGIN{ exit !($delay >= 1.0) }" 2>/dev/null || delay=1.5

    # Resolve a window reference. A numeric ref (X11 id / HWND) works on any OS;
    # name/active-window resolution is X11-only for now (use run_and_screenshot,
    # which resolves by PID, on macOS/Windows).
    local os; os=$(_qb_os)
    local winid=""
    if [[ "$window" =~ ^[0-9]+$ ]]; then
        winid="$window"
    elif [[ -n "$window" ]]; then
        if [[ "$os" == linux ]]; then
            winid=$(xdotool search --name "$window" 2>/dev/null | head -1)
            [[ -z "$winid" ]] && { echo "No window matching name '$window'."; return 1; }
        else
            echo "Name-based window lookup isn't supported yet on $os for 'screenshot'. Pass a numeric window ref, or use run_and_screenshot {\"binary\":...} (resolves by PID)."
            return 1
        fi
    else
        if [[ "$os" == linux ]]; then
            winid=$(xdotool getactivewindow 2>/dev/null)
            [[ -z "$winid" ]] && { echo "No active window and no 'window' given."; return 1; }
        else
            echo "Capturing the active window isn't supported yet on $os; provide a 'window' reference, or use run_and_screenshot."
            return 1
        fi
    fi

    if [[ -z "$output" ]]; then
        output="${TMPDIR:-/tmp}/qb64pe-shot-$(date +%Y%m%d-%H%M%S)-$$.png"
    fi

    # Liveness pre-check: capturing an already-closed window yields a broken PNG.
    if ! _qb_window_alive "$winid" "$winid"; then
        echo "Window $winid is no longer present (closed before capture)."
        return 1
    fi

    # Activate → release keys → settle → re-check liveness → capture (per OS).
    _qb_capture_window "$winid" "$winid" "$output" "$delay"
    case "$?" in
        0)  echo "Screenshot saved: $output"
            echo "(Read this file with the Read tool to view it. Compare visible content, not file size.)"
            return 0 ;;
        2)  echo "Window $winid closed during the settle delay — nothing to capture."
            return 1 ;;
        3)  echo "No screenshot backend found for this OS (Linux: install ImageMagick 'import' or scrot)."
            return 1 ;;
        *)  [[ -f "$output" ]] && rm -f "$output"
            echo "Capture failed or produced a zero-byte image (window closed before capture?)."
            return 1 ;;
    esac
}
