#!/bin/bash
# platform.sh — OS abstraction for the run/stop/screenshot/compile tools.
#
# Linux/X11 is the TESTED reference path. macOS and Windows (Git Bash/MSYS2) are
# implemented with native commands but marked "VALIDATE ON-DEVICE" until exercised
# on real hardware — the maintainer owns both but can't test them from here.
# WSL reports uname=Linux, so it rides the X11 path (needs WSLg for a GUI).
#
# Contract (the tools call ONLY these; never a raw xdotool/screencapture/PowerShell):
#   _qb_os                       -> linux | macos | windows
#   _qb_exe_suffix               -> "" or ".exe"
#   _qb_launch BIN ARGS          -> echoes the PID used for teardown/window lookup
#   _qb_kill_group PID           -> tear down the program + its children, by integer
#   _qb_window_list              -> pre-launch window snapshot (X11 only; else empty)
#   _qb_resolve_window PID HINT SNAP TRIES -> opaque per-OS window reference (or empty)
#   _qb_window_alive REF PID     -> 0 if the target window/process is still alive
#   _qb_capture_window REF PID OUT DELAY -> capture to PNG; 0 ok / 2 closed / 3 no-backend / 1 fail
#   _qb_gui_ready                -> 0 if this OS can screenshot now; else echoes why, returns 1
#   _qb_pty_compile SRCDIR CMD   -> run the compile CMD under a pty; echoes output, returns its exit
#   _qb_platform_report          -> human-readable capability report (for the `doctor` tool)

# ---- OS detection -----------------------------------------------------------
_QB_OS_CACHE=""
_qb_os() {
    if [[ -z "$_QB_OS_CACHE" ]]; then
        case "$(uname -s 2>/dev/null)" in
            Darwin)               _QB_OS_CACHE=macos ;;
            MINGW*|MSYS*|CYGWIN*) _QB_OS_CACHE=windows ;;
            *) [[ -n "$MSYSTEM" ]] && _QB_OS_CACHE=windows || _QB_OS_CACHE=linux ;;
        esac
    fi
    printf '%s' "$_QB_OS_CACHE"
}

# True under WSL — still the X11 path, but worth flagging in messages/doctor.
_qb_is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

# Executable suffix QB64PE appends on this OS.
_qb_exe_suffix() { [[ "$(_qb_os)" == windows ]] && printf '.exe'; }

# Locate a usable PowerShell (Windows).
_qb_powershell() { command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || command -v pwsh 2>/dev/null; }

# ---- launch (detached, own session/group where the OS supports it) -----------
_qb_launch() {
    local binary="$1" rargs="$2" pid winpid
    case "$(_qb_os)" in
        linux)
            # setsid execs the binary (no extra fork in this non-interactive
            # context), so $! is the binary's PID == its PGID for teardown.
            if [[ -n "$rargs" ]]; then setsid "$binary" $rargs >/dev/null 2>&1 </dev/null &
            else                       setsid "$binary"        >/dev/null 2>&1 </dev/null & fi
            echo $! ;;
        macos)
            # macOS ships no `setsid`; use it if brew-installed, else a perl shim
            # (perl ships with macOS) to become a session/group leader.
            if command -v setsid &>/dev/null; then
                if [[ -n "$rargs" ]]; then setsid "$binary" $rargs >/dev/null 2>&1 </dev/null &
                else                       setsid "$binary"        >/dev/null 2>&1 </dev/null & fi
            else
                # shellcheck disable=SC2086
                perl -MPOSIX=setsid -e 'setsid(); exec @ARGV or exit 127' "$binary" $rargs >/dev/null 2>&1 </dev/null &
            fi
            echo $! ;;
        windows)
            # Git Bash/MSYS2: launch the native .exe; teardown is by process TREE
            # (taskkill /T), so no POSIX group is needed. Resolve the *Windows* PID
            # (winpid) — $! is the MSYS pid, which taskkill/Get-Process can't use.
            # shellcheck disable=SC2086
            if [[ -n "$rargs" ]]; then "$binary" $rargs >/dev/null 2>&1 </dev/null &
            else                       "$binary"        >/dev/null 2>&1 </dev/null & fi
            pid=$!
            winpid=$(cat "/proc/$pid/winpid" 2>/dev/null)
            [[ -n "$winpid" ]] && echo "$winpid" || echo "$pid" ;;
    esac
}

# ---- teardown (program + children) by integer only --------------------------
_qb_kill_group() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ "$(_qb_os)" == windows ]]; then
        # Tree-kill by native PID. MSYS_NO_PATHCONV stops /PID being path-mangled.
        MSYS_NO_PATHCONV=1 taskkill /PID "$pid" /T /F >/dev/null 2>&1
        return 0
    fi
    # POSIX (linux/macos): signal the whole process group (negative pid).
    local target
    if   kill -0 "-$pid" 2>/dev/null; then target="-$pid"
    elif kill -0  "$pid" 2>/dev/null; then target="$pid"
    else return 0; fi
    kill -TERM "$target" 2>/dev/null
    local i
    for ((i=0; i<10; i++)); do
        kill -0 "$target" 2>/dev/null || return 0
        sleep 0.2
    done
    kill -KILL "$target" 2>/dev/null
    return 0
}

# ---- window snapshot (X11 only — windows aren't PID-linked there) ------------
_qb_window_list() {
    [[ "$(_qb_os)" == linux ]] || return 0
    command -v xdotool &>/dev/null || return 0
    [[ -n "$DISPLAY" ]] || return 0
    xdotool search --name '.*' 2>/dev/null | sort -u
}

# ---- resolve the window a freshly-launched program opened -------------------
_qb_resolve_window() {
    local pid="$1" hint="$2" before="$3" tries="${4:-30}"
    case "$(_qb_os)" in
        linux)   _qb_resolve_window_x11     "$pid" "$hint" "$before" "$tries" ;;
        macos)   _qb_resolve_window_macos   "$pid" "$hint" "$tries" ;;
        windows) _qb_resolve_window_windows "$pid" "$hint" "$tries" ;;
    esac
}

# X11: QB64PE/SDL2 don't set _NET_WM_PID, so identify the window that APPEARED
# since the pre-launch snapshot (newest id wins); honor a _TITLE hint first.
_qb_resolve_window_x11() {
    local pid="$1" hint="$2" before="$3" tries="$4" i winid="" before_s now new
    command -v xdotool &>/dev/null || return 0
    [[ -n "$DISPLAY" ]] || return 0
    before_s=$(printf '%s\n' "$before" | sort -u)
    for ((i=0; i<tries; i++)); do
        if [[ -n "$hint" ]]; then
            winid=$(xdotool search --name "$hint" 2>/dev/null | head -1)
            [[ -n "$winid" ]] && { echo "$winid"; return 0; }
        fi
        winid=$(xdotool search --pid "$pid" 2>/dev/null | head -1)   # works if a build sets _NET_WM_PID
        [[ -n "$winid" ]] && { echo "$winid"; return 0; }
        now=$(xdotool search --name '.*' 2>/dev/null | sort -u)
        new=$(comm -13 <(printf '%s\n' "$before_s") <(printf '%s\n' "$now") | grep -E '^[0-9]+$')
        winid=$(printf '%s\n' "$new" | tail -1)
        [[ -n "$winid" ]] && { echo "$winid"; return 0; }
        sleep 0.2
    done
    return 0
}

# macOS: Windows are tied to the owning process via System Events `unix id`. The
# reference we return IS the pid (capture re-queries the front window's bounds).
# VALIDATE ON-DEVICE.
_qb_resolve_window_macos() {
    local pid="$1" hint="$2" tries="$3" i has
    command -v osascript &>/dev/null || return 0
    for ((i=0; i<tries; i++)); do
        has=$(osascript -e 'on run {p}' \
                        -e 'tell application "System Events"' \
                        -e 'try' \
                        -e 'set proc to first process whose unix id is (p as integer)' \
                        -e 'if (count of windows of proc) > 0 then return "yes"' \
                        -e 'end try' \
                        -e 'return ""' \
                        -e 'end tell' "$pid" 2>/dev/null)
        [[ "$has" == "yes" ]] && { echo "$pid"; return 0; }
        sleep 0.2
    done
    return 0
}

# Windows: the OS links windows to PIDs directly — MainWindowHandle is the HWND.
# VALIDATE ON-DEVICE.
_qb_resolve_window_windows() {
    local pid="$1" hint="$2" tries="$3" i ps hwnd
    ps=$(_qb_powershell); [[ -n "$ps" ]] || return 0
    for ((i=0; i<tries; i++)); do
        hwnd=$(MSYS_NO_PATHCONV=1 "$ps" -NoProfile -Command \
            "\$p=Get-Process -Id $pid -ErrorAction SilentlyContinue; if(\$p -and \$p.MainWindowHandle -ne 0){[int64]\$p.MainWindowHandle}" 2>/dev/null | tr -d '\r')
        [[ "$hwnd" =~ ^[0-9]+$ && "$hwnd" != "0" ]] && { echo "$hwnd"; return 0; }
        sleep 0.2
    done
    return 0
}

# ---- is a launched PID still alive? (for `stop`) ----------------------------
_qb_pid_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ "$(_qb_os)" == windows ]]; then
        local ps; ps=$(_qb_powershell); [[ -n "$ps" ]] || return 1
        MSYS_NO_PATHCONV=1 "$ps" -NoProfile -Command \
            "if(Get-Process -Id $pid -ErrorAction SilentlyContinue){exit 0}else{exit 1}" >/dev/null 2>&1
        return $?
    fi
    kill -0 "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null
}

# ---- liveness ---------------------------------------------------------------
_qb_window_alive() {
    local ref="$1" pid="$2"
    case "$(_qb_os)" in
        linux)   xdotool getwindowname "$ref" &>/dev/null ;;
        macos)   kill -0 "$pid" 2>/dev/null ;;
        windows) local ps; ps=$(_qb_powershell); [[ -n "$ps" ]] &&
                 MSYS_NO_PATHCONV=1 "$ps" -NoProfile -Command \
                   "if(Get-Process -Id $pid -ErrorAction SilentlyContinue){exit 0}else{exit 1}" >/dev/null 2>&1 ;;
    esac
}

# ---- can we screenshot on this OS right now? --------------------------------
_qb_gui_ready() {
    case "$(_qb_os)" in
        linux)
            [[ -n "$DISPLAY" ]] || { echo "DISPLAY is unset — cannot capture a screenshot (need an X display; under WSL use WSLg)."; return 1; }
            command -v xdotool &>/dev/null || { echo "xdotool is required for window capture on Linux/X11 (e.g. 'sudo apt install xdotool')."; return 1; }
            command -v import &>/dev/null || command -v scrot &>/dev/null || { echo "No screenshot backend — install ImageMagick ('import') or scrot."; return 1; }
            return 0 ;;
        macos)
            command -v screencapture &>/dev/null || { echo "screencapture not found (it ships with macOS — unexpected)."; return 1; }
            command -v osascript &>/dev/null     || { echo "osascript not found (it ships with macOS — unexpected)."; return 1; }
            return 0 ;;
        windows)
            [[ -n "$(_qb_powershell)" ]] || { echo "PowerShell not found — required for window capture on Windows (Git Bash/MSYS2)."; return 1; }
            return 0 ;;
    esac
}

# ---- capture: activate, settle, grab to PNG ---------------------------------
# Returns: 0 saved (non-empty) | 2 window closed during settle | 3 no backend | 1 fail/zero-byte.
_qb_capture_window() {
    local ref="$1" pid="$2" output="$3" delay="$4"
    case "$(_qb_os)" in
        linux)   _qb_capture_window_x11     "$ref" "$pid" "$output" "$delay" ;;
        macos)   _qb_capture_window_macos   "$ref" "$pid" "$output" "$delay" ;;
        windows) _qb_capture_window_windows "$ref" "$pid" "$output" "$delay" ;;
    esac
}

_qb_capture_window_x11() {
    local winid="$1" pid="$2" output="$3" delay="$4"
    xdotool windowactivate "$winid" 2>/dev/null
    xdotool keyup --window "$winid" ctrl alt shift super 2>/dev/null
    sleep "$delay"
    _qb_window_alive "$winid" "$pid" || return 2
    if command -v import &>/dev/null; then timeout 20 import -window "$winid" "$output" 2>/dev/null
    elif command -v scrot &>/dev/null; then timeout 20 scrot -o "$output" 2>/dev/null
    else return 3; fi
    [[ -s "$output" ]] && return 0 || return 1
}

# macOS: activate the owning process, read the front window's bounds via System
# Events, then screencapture that region (built-ins only). VALIDATE ON-DEVICE.
_qb_capture_window_macos() {
    # On macOS the window "reference" IS the owning pid (System Events keys on it).
    local ppid="$1" output="$3" delay="$4"
    command -v screencapture &>/dev/null || return 3
    local bounds
    bounds=$(osascript -e 'on run {p}' \
                       -e 'tell application "System Events"' \
                       -e 'set proc to first process whose unix id is (p as integer)' \
                       -e 'set frontmost of proc to true' \
                       -e 'set w to front window of proc' \
                       -e 'set {x, y} to position of w' \
                       -e 'set {ww, hh} to size of w' \
                       -e 'return (x as string) & "," & (y as string) & "," & (ww as string) & "," & (hh as string)' \
                       -e 'end tell' "$ppid" 2>/dev/null)
    sleep "$delay"
    _qb_window_alive "$ppid" "$ppid" || return 2
    [[ "$bounds" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]] || return 1
    screencapture -x -R"$bounds" "$output" 2>/dev/null
    [[ -s "$output" ]] && return 0 || return 1
}

# Windows: SetForegroundWindow(hwnd), GetWindowRect, CopyFromScreen -> PNG, via an
# inline C#/PowerShell helper. VALIDATE ON-DEVICE.
_qb_capture_window_windows() {
    local hwnd="$1" pid="$2" output="$3" delay="$4" ps
    ps=$(_qb_powershell); [[ -n "$ps" ]] || return 3
    sleep "$delay"
    _qb_window_alive "$hwnd" "$pid" || return 2
    local winpath; winpath=$(command -v cygpath &>/dev/null && cygpath -w "$output" || echo "$output")
    MSYS_NO_PATHCONV=1 "$ps" -NoProfile -STA -Command "
\$ErrorActionPreference='SilentlyContinue'
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class W{[DllImport(\"user32.dll\")]public static extern bool SetForegroundWindow(IntPtr h);[DllImport(\"user32.dll\")]public static extern bool GetWindowRect(IntPtr h,out RECT r);public struct RECT{public int L,T,R,B;}}'
Add-Type -AssemblyName System.Drawing
\$h=[IntPtr]$hwnd; [W]::SetForegroundWindow(\$h); Start-Sleep -Milliseconds 250
\$r=New-Object W+RECT; [void][W]::GetWindowRect(\$h,[ref]\$r)
\$w=\$r.R-\$r.L; \$ht=\$r.B-\$r.T; if(\$w -le 0 -or \$ht -le 0){exit 1}
\$bmp=New-Object System.Drawing.Bitmap \$w,\$ht
\$g=[System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$r.L,\$r.T,0,0,\$bmp.Size)
\$bmp.Save('$winpath',[System.Drawing.Imaging.ImageFormat]::Png)
" >/dev/null 2>&1
    [[ -s "$output" ]] && return 0 || return 1
}

# ---- compile under a pty (preserves QB64PE's TTY error display) -------------
_qb_pty_compile() {
    local srcdir="$1" cmd="$2"
    case "$(_qb_os)" in
        macos)
            # BSD `script`: `script -q out cmd args...`.
            ( cd "$srcdir" && script -q /dev/null bash -c "$cmd" 2>&1 ) ;;
        windows)
            # MSYS2 may lack util-linux `script`; fall back to a direct run (loses
            # the pty TTY display but still compiles).
            if command -v script &>/dev/null; then ( cd "$srcdir" && script -qefc "$cmd" /dev/null 2>&1 )
            else ( cd "$srcdir" && bash -c "$cmd" 2>&1 ); fi ;;
        *)
            # Linux util-linux `script`: -e returns child exit, -q quiet, -f flush.
            ( cd "$srcdir" && script -qefc "$cmd" /dev/null 2>&1 ) ;;
    esac
}

# ---- capability report (the `doctor` tool) ----------------------------------
_qb_platform_report() {
    local os; os=$(_qb_os)
    local wsl=""; _qb_is_wsl && wsl=" (WSL)"
    echo "QB64PE MCP — platform capabilities"
    echo "=================================="
    echo "OS class        : ${os}${wsl}"
    echo "uname           : $(uname -srm 2>/dev/null)"
    echo "exe suffix      : '$(_qb_exe_suffix)'"
    echo

    local comp; comp=$(_qb_find_compiler)
    _qb_doc_line "QB64PE compiler" "$([[ -n "$comp" ]] && echo "$comp" || echo MISSING)" \
        "$([[ -n "$comp" ]] && echo ok || echo "set QB64PE_BIN to the qb64pe path")"

    case "$os" in
        linux)
            _qb_doc_line "pty (script)"   "$(command -v script || echo MISSING)" "$(command -v script >/dev/null && echo ok || echo 'install util-linux')"
            _qb_doc_line "launch/teardown" "setsid + kill -<pgid>" "$(command -v setsid >/dev/null && echo ok || echo 'install util-linux (setsid)')"
            _qb_doc_line "display"          "${DISPLAY:-<unset>}" "$([[ -n "$DISPLAY" ]] && echo ok || echo 'no X display — start one / use WSLg')"
            _qb_doc_line "window control"   "$(command -v xdotool || echo MISSING)" "$(command -v xdotool >/dev/null && echo ok || echo 'install xdotool')"
            _qb_doc_line "capture backend"  "$(command -v import || command -v scrot || echo MISSING)" "$({ command -v import || command -v scrot; } >/dev/null && echo ok || echo 'install imagemagick or scrot')"
            ;;
        macos)
            _qb_doc_line "pty (script)"     "$(command -v script || echo MISSING)" ok
            _qb_doc_line "launch/teardown"  "$(command -v setsid >/dev/null && echo 'setsid' || echo 'perl setsid shim') + kill -<pgid>" "$(command -v perl >/dev/null && echo ok || echo 'perl needed for the setsid shim (or brew install util-linux)')"
            _qb_doc_line "window control"   "$(command -v osascript || echo MISSING)" "$(command -v osascript >/dev/null && echo ok || echo 'osascript ships with macOS')"
            _qb_doc_line "capture backend"  "$(command -v screencapture || echo MISSING)" "$(command -v screencapture >/dev/null && echo ok || echo 'screencapture ships with macOS')"
            echo "  NOTE: macOS capture/window paths are implemented but pending on-device validation."
            ;;
        windows)
            _qb_doc_line "pty (script)"     "$(command -v script || echo 'MISSING -> direct exec fallback')" ok
            _qb_doc_line "launch"           "background .exe + winpid" "$([[ -r /proc/self/winpid ]] && echo ok || echo 'winpid resolution unverified on this shell')"
            _qb_doc_line "teardown"         "taskkill /T /F" "$(command -v taskkill >/dev/null && echo ok || echo 'taskkill not on PATH')"
            _qb_doc_line "window+capture"   "$(_qb_powershell || echo MISSING)" "$([[ -n "$(_qb_powershell)" ]] && echo ok || echo 'PowerShell required')"
            echo "  NOTE: Windows capture/window paths are implemented but pending on-device validation."
            ;;
    esac
    echo
    echo "Tools that work everywhere (no GUI deps): wiki_page, wiki_search, keyword_lookup, lint, inject_logging, compile."
    echo "GUI tools (run/stop/run_and_screenshot/screenshot) need the per-OS pieces above."
}
_qb_doc_line() { printf '  %-16s: %-40s [%s]\n' "$1" "$2" "$3"; }

# tool_doctor — report this machine's cross-platform capabilities.
tool_doctor() { _qb_platform_report; return 0; }
