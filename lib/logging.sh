#!/bin/bash
# logging.sh — tool_inject_logging.
# Adds native QB64PE console+logging scaffolding so a program's output is capturable
# for automated debugging. Non-destructive by default: returns the enhanced code;
# only writes to disk when 'output' is supplied.

# Heuristic: does this source open a graphics window? If so, $CONSOLE:ONLY would
# SUPPRESS that window and break a GUI program (e.g. DRAW) — such programs must use
# $CONSOLE (console alongside the graphics window), never $CONSOLE:ONLY.
_qb_is_graphics() {
    local f="$1"
    # A graphics SCREEN mode (SCREEN _NEWIMAGE / SCREEN 1,2,7..13,...; NOT SCREEN 0).
    grep -qiE '(^|:)[[:space:]]*SCREEN[[:space:]]+(_NEWIMAGE|[1-9])' "$f" 2>/dev/null && return 0
    # Image / display / window-title primitives (strong GUI signals).
    grep -qiE '\b(_NEWIMAGE|_DISPLAY|_PUTIMAGE|_LOADIMAGE|_TITLE|_ICON|_FULLSCREEN)\b' "$f" 2>/dev/null && return 0
    # Drawing primitives.
    grep -qiE '\b(PSET|PRESET|CIRCLE|PAINT|DRAW|_PRINTSTRING|_DEST|_SOURCE|PCOPY)\b' "$f" 2>/dev/null && return 0
    grep -qiE '\bLINE[[:space:]]*\(' "$f" 2>/dev/null && return 0   # LINE (x,y)-... (graphics), not LINE INPUT
    return 1
}

tool_inject_logging() {
    local args="$1"
    local mode output
    mode=$(echo "$args" | jq -r '.mode // "auto"')
    output=$(echo "$args" | jq -r '.output // empty')

    if ! _qb_materialize "$args" "bas"; then
        echo "${QB_MAT_ERR:-Provide either 'file' (path) or 'code' (inline).}"
        return 1
    fi
    local src="$QB_SRC"

    # Choose the console directive. $CONSOLE:ONLY = NO graphics window (text/console
    # programs only); $CONSOLE = console + the graphics window (GUI programs). 'auto'
    # detects which the program needs so a GUI app's window is never suppressed.
    local is_gfx=0; _qb_is_graphics "$src" && is_gfx=1
    local directive note
    case "$mode" in
        graphics)
            directive="\$CONSOLE"
            note="mode=graphics → \$CONSOLE (graphics window kept)." ;;
        console)
            directive="\$CONSOLE:ONLY"
            if [[ $is_gfx -eq 1 ]]; then
                note="mode=console (explicit) → \$CONSOLE:ONLY. WARNING: this source looks like a GUI program (graphics SCREEN/_DISPLAY/drawing detected); \$CONSOLE:ONLY SUPPRESSES the graphics window. Use mode=graphics (or auto) to keep it."
            else
                note="mode=console → \$CONSOLE:ONLY (console-only; no graphics window)."
            fi ;;
        *) # auto (default)
            if [[ $is_gfx -eq 1 ]]; then
                directive="\$CONSOLE"
                note="mode=auto → \$CONSOLE (graphics detected; graphics window kept alongside the console)."
            else
                directive="\$CONSOLE:ONLY"
                note="mode=auto → \$CONSOLE:ONLY (no graphics detected; console-only)."
            fi ;;
    esac

    local has_console=0 has_only=0
    if grep -qiE '^[[:space:]]*[$]CONSOLE' "$src"; then
        has_console=1
        grep -qiE '^[[:space:]]*[$]CONSOLE:ONLY\b' "$src" && has_only=1
    fi
    # If the source ALREADY declares a directive we won't add ours — but a
    # pre-existing $CONSOLE:ONLY in a GUI program is itself a bug (its window is
    # suppressed), so surface that instead of the add-decision note.
    if [[ $has_console -eq 1 ]]; then
        if [[ $has_only -eq 1 && $is_gfx -eq 1 ]]; then
            note="kept your existing \$CONSOLE:ONLY — but this looks like a GUI program, so that directive SUPPRESSES the graphics window. Change it to \$CONSOLE if you need the window to show."
        else
            note="kept your existing \$CONSOLE directive (no change needed)."
        fi
    fi

    local prog_name
    prog_name=$(basename "$src")

    # Build the enhanced program.
    local header
    header="' === logging injected by qb64pe-mcp-server-bash (mode=$mode) ===
' _LOGINFO/_LOGWARN/_LOGERROR write to the QB64PE log; \$CONSOLE makes output capturable.
' _ECHO is the native console print that also works in graphics modes."

    {
        if [[ $has_console -eq 0 ]]; then
            echo "$directive"
        fi
        echo "$header"
        echo "_LOGINFO \"=== ${prog_name} starting (qb64pe-mcp logging) ===\""
        echo
        cat "$src"
    } > "${src}.enhanced.$$"

    local enhanced; enhanced=$(cat "${src}.enhanced.$$")
    rm -f "${src}.enhanced.$$"
    _qb_cleanup

    if [[ -n "$output" ]]; then
        printf '%s\n' "$enhanced" > "$output"
        if [[ $has_console -eq 1 ]]; then
            echo "Wrote enhanced program to: $output (existing \$CONSOLE directive kept; added _LOGINFO startup banner)."
        else
            echo "Wrote enhanced program to: $output (added '$directive' + _LOGINFO startup banner)."
        fi
        echo "Console directive: $note"
        return 0
    fi

    if [[ $has_console -eq 1 ]]; then
        echo "// Enhanced (existing \$CONSOLE kept; added startup logging). Source NOT modified."
    else
        echo "// Enhanced with '$directive' + startup logging. Source NOT modified."
    fi
    echo "// Console directive: $note"
    echo "// ---------------------------------------------------------------"
    printf '%s\n' "$enhanced"
    return 0
}
