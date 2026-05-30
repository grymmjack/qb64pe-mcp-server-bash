#!/bin/bash
# common.sh — shared helpers. Sourced FIRST (before other lib/*.sh) by the entry script.

# Locate the QB64PE compiler. Honors $QB64PE_BIN, then PATH, then known install spots.
_qb_find_compiler() {
    if [[ -n "$QB64PE_BIN" && -x "$QB64PE_BIN" ]]; then
        echo "$QB64PE_BIN"; return 0
    fi
    local c
    for c in qb64pe qb64; do
        if command -v "$c" &>/dev/null; then command -v "$c"; return 0; fi
    done
    for c in \
        "/home/grymmjack/git/qb64pe/qb64pe" \
        "$HOME/qb64pe/qb64pe" \
        "/usr/local/qb64pe/qb64pe" \
        "/opt/qb64pe/qb64pe"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# Resolve a tool's source input to a real file path.
# Sets QB_SRC (path), QB_SRC_TMP (1 if a temp file we must clean up), and QB_MAT_ERR
# (error message on failure). MUST be called directly (not in $(...)) so the globals
# survive in the caller's shell. Returns: 0 ok, 1 no input, 2 file-not-found.
_qb_materialize() {
    local args="$1" ext="${2:-bas}"
    QB_SRC=""; QB_SRC_TMP=0; QB_MAT_ERR=""
    local file code
    file=$(echo "$args" | jq -r '.file // empty')
    code=$(echo "$args" | jq -r '.code // empty')
    if [[ -n "$file" ]]; then
        if [[ ! -f "$file" ]]; then
            QB_MAT_ERR="File not found: $file"
            return 2
        fi
        QB_SRC="$file"
        return 0
    fi
    if [[ -n "$code" ]]; then
        QB_SRC="$(mktemp --suffix=".$ext" 2>/dev/null || mktemp)"
        printf '%s\n' "$code" > "$QB_SRC"
        QB_SRC_TMP=1
        return 0
    fi
    QB_MAT_ERR="Provide either 'file' (path) or 'code' (inline)."
    return 1
}

# Clean up a temp source created by _qb_materialize.
_qb_cleanup() {
    [[ "$QB_SRC_TMP" == "1" && -n "$QB_SRC" && -f "$QB_SRC" ]] && rm -f "$QB_SRC"
    QB_SRC=""; QB_SRC_TMP=0
}
