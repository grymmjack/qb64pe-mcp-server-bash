#!/bin/bash
# lint.sh — tool_lint. Two layers:
#   A) QB64PE compiler -z fast syntax check (authoritative; catches the 69%-syntax bulk)
#   B) regex rules for runtime-semantic traps the compiler accepts but that crash/misbehave
# Layer-B findings accumulate in $LINT_OUT as "SEVERITY|LINE|RULE|MESSAGE" (single-line) entries.
# Layer-A result is reported separately via $LINT_SYNTAX / $LINT_SYNTAX_MSG.

_lint_add() {
    # collapse any newlines in the message so each finding stays one line
    local msg; msg=$(printf '%s' "$4" | tr '\n' ' ')
    LINT_OUT+="$1|$2|$3|$msg"$'\n'
}

# --- Layer A: compiler syntax check ---------------------------------------
# $2 = "1" to add -e (enforce declaration). Off by default: -e floods projects
# that don't use OPTION _EXPLICIT (e.g. DRAW) with false "undeclared" errors.
_lint_layer_a() {
    local target="$1" enforce="$2"
    local comp; comp=$(_qb_find_compiler)
    if [[ -z "$comp" ]]; then
        LINT_SYNTAX="NOCOMP"
        LINT_SYNTAX_MSG="QB64PE compiler not found (set QB64PE_BIN env var). Ran regex rules only."
        return
    fi
    local eflag=""; [[ "$enforce" == "1" ]] && eflag="-e"
    local out crc
    # -z transpile-only (no exe), -w warnings (unused vars), -m monochrome, -q quiet.
    out=$(cd "$(dirname "$target")" && "$comp" -z $eflag -w -m -q "$target" 2>&1); crc=$?
    local clean; clean=$(echo "$out" | sed '/^[[:space:]]*$/d')
    if [[ $crc -eq 0 && -z "$clean" ]]; then
        LINT_SYNTAX="PASS"; LINT_SYNTAX_MSG=""
    elif [[ -n "$clean" ]]; then
        LINT_SYNTAX="FAIL"; LINT_SYNTAX_MSG="$clean"
    else
        LINT_SYNTAX="FAIL"
        LINT_SYNTAX_MSG="Compiler -z exited $crc with no text (possible blocked internal/temp dir, or missing deps)."
    fi
}

# --- Layer B: regex rules --------------------------------------------------
_lint_layer_b() {
    local file="$1" ext="$2"

    # B1. Function self-reference -> SIGSEGV (crown jewel)
    local sr; sr=$(awk -f "$QB_ROOT/lib/selfref.awk" "$file" 2>/dev/null)
    if [[ -n "$sr" ]]; then
        local ln tok txt
        while IFS=$'\t' read -r ln tok txt; do
            [[ -z "$ln" ]] && continue
            _lint_add "error" "$ln" "self-reference" "Reading FUNCTION's own name '$tok' here is a RECURSIVE CALL (SIGSEGV), not a variable read: \`$txt\`. Assign once via a local: DIM r ... : $tok = r."
        done <<< "$sr"
    fi

    # B2. FUNCTION return type via AS (must use a sigil; if UDT, use SUB BYREF)
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        _lint_add "error" "$ln" "return-type" "FUNCTION return type uses 'AS' — QB64PE needs a SIGIL (e.g. FUNCTION Foo%). If the type is a UDT, use a SUB with a BYREF param instead."
    done < <(grep -nEi '^[[:space:]]*FUNCTION[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\([^)]*\))?[[:space:]]+AS[[:space:]]+[A-Za-z_]' "$file" 2>/dev/null)

    # B3. stray DECLARE SUB/FUNCTION (only DECLARE LIBRARY is needed)
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        _lint_add "warn" "$ln" "declare" "DECLARE SUB/FUNCTION is unnecessary in QB64PE (procedures are auto-discovered). Remove it; keep only DECLARE LIBRARY."
    done < <(grep -nEi '^[[:space:]]*DECLARE[[:space:]]+(SUB|FUNCTION)\b' "$file" 2>/dev/null)

    # B4. bare TRUE/FALSE with no CONST in THIS file -> ONE summary note (they're
    # often defined in an included .BI, which a single-file scan can't see).
    if grep -qEi '\b(TRUE|FALSE)\b' "$file" 2>/dev/null && \
       ! grep -qEi '\bCONST[[:space:]]+(TRUE|FALSE)[[:space:]]*=' "$file" 2>/dev/null; then
        local tfn tfline
        tfn=$(grep -cEi '\b(TRUE|FALSE)\b' "$file" 2>/dev/null)
        tfline=$(grep -nEi '\b(TRUE|FALSE)\b' "$file" 2>/dev/null | head -1 | cut -d: -f1)
        _lint_add "info" "${tfline:-0}" "true-false" "TRUE/FALSE used ${tfn}x but no 'CONST TRUE/FALSE =' in this file. QB64PE doesn't define them by default — ensure they're defined here or in an included .BI (otherwise they silently default to 0)."
    fi

    # B5. DIM SHARED in a .BM file (belongs in .BI)
    if [[ "$ext" == "bm" ]]; then
        while IFS=: read -r ln _; do
            [[ -z "$ln" ]] && continue
            _lint_add "error" "$ln" "dim-shared-placement" "DIM SHARED in a .BM file -> 'Statement cannot be placed between SUB/FUNCTIONs'. Move declarations to the matching .BI file."
        done < <(grep -nEi '^[[:space:]]*DIM[[:space:]]+SHARED\b' "$file" 2>/dev/null)
    fi

    # B6. reserved-word variable collisions (regex fallback; Layer A also catches these)
    if [[ -f "$QB_DATA/reserved-words.txt" ]]; then
        local ln name
        while IFS=$'\t' read -r ln name; do
            [[ -z "$ln" ]] && continue
            _lint_add "error" "$ln" "reserved-word" "Variable '$name' collides with a QB64PE reserved word -> 'Name already in use'. Rename it (e.g. ${name}_v)."
        done < <(awk 'BEGIN{ while((getline w < ARGV[1])>0){ res[toupper(w)]=1 } ARGV[1]="" }
            { if(match(toupper($0),/^[ \t]*DIM[ \t]+(SHARED[ \t]+)?[A-Z_][A-Z0-9_]*/)){
                  s=toupper($0); sub(/^[ \t]*DIM[ \t]+(SHARED[ \t]+)?/,"",s)
                  if(match(s,/^[A-Z_][A-Z0-9_]*/)){ nm=substr(s,1,RLENGTH); if(res[nm]) print NR"\t"nm }
            } }' "$QB_DATA/reserved-words.txt" "$file" 2>/dev/null)
    fi

    # B7. _LOADIMAGE with a literal empty filename (std::bad_alloc risk)
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        _lint_add "warn" "$ln" "loadimage-empty" "_LOADIMAGE with an empty filename can crash with std::bad_alloc. Validate the filename before loading."
    done < <(grep -nEi '_LOADIMAGE[[:space:]]*\([[:space:]]*""' "$file" 2>/dev/null)

    # B8. NOT used as a boolean (bitwise gotcha) — heuristic, low severity
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        _lint_add "info" "$ln" "not-bitwise" "NOT is BITWISE in QB64PE (NOT 1 = -2, still truthy). For a boolean flag use 'IF flag = 0' instead of 'IF NOT flag'."
    done < <(grep -nEi '\bIF\b[^'"'"']*\bNOT[[:space:]]+[A-Za-z_]' "$file" 2>/dev/null | grep -viE '\bNOT[[:space:]]*\(')
}

tool_lint() {
    local args="$1"
    LINT_OUT=""; LINT_SYNTAX="SKIP"; LINT_SYNTAX_MSG=""

    if ! _qb_materialize "$args" "bas"; then
        echo "${QB_MAT_ERR:-Provide either 'file' (path) or 'code' (inline).}"
        return 1
    fi
    local file="$QB_SRC"
    local ext="${file##*.}"; ext="${ext,,}"
    local syntaxCheck projectEntry enforce
    # NOTE: jq '//' treats false as empty, so '.syntaxCheck // true' would wrongly
    # yield true for an explicit false. Compare explicitly instead.
    syntaxCheck=$(echo "$args" | jq -r 'if .syntaxCheck == false then "false" else "true" end')
    projectEntry=$(echo "$args" | jq -r '.projectEntry // empty')
    enforce=$(echo "$args" | jq -r 'if .enforceDeclaration == true then "1" else "0" end')

    # Layer A
    if [[ "$syntaxCheck" != "false" ]]; then
        local target="$file"
        if [[ "$ext" == "bi" || "$ext" == "bm" ]]; then
            if [[ -n "$projectEntry" && -f "$projectEntry" ]]; then
                target="$projectEntry"
            else
                target=""; LINT_SYNTAX="FRAGMENT"
                LINT_SYNTAX_MSG="Standalone .$ext fragment — pass 'projectEntry' (the entry .BAS) to enable the compiler check. Regex rules only."
            fi
        fi
        [[ -n "$target" ]] && _lint_layer_a "$target" "$enforce"
    fi

    # Layer B (always)
    _lint_layer_b "$file" "$ext"
    _qb_cleanup

    # Render
    local errs warns infos
    errs=$(grep -c '^error|' <<< "$LINT_OUT"); warns=$(grep -c '^warn|' <<< "$LINT_OUT"); infos=$(grep -c '^info|' <<< "$LINT_OUT")
    echo "QB64PE lint"
    echo "==========="
    case "$LINT_SYNTAX" in
        PASS)     echo "Syntax (compiler -z): PASSED — no errors." ;;
        FAIL)     echo "Syntax (compiler -z): FAILED:"; echo "$LINT_SYNTAX_MSG" | sed 's/^/    /' ;;
        NOCOMP)   echo "Syntax (compiler -z): SKIPPED — $LINT_SYNTAX_MSG" ;;
        FRAGMENT) echo "Syntax (compiler -z): SKIPPED — $LINT_SYNTAX_MSG" ;;
        SKIP)     echo "Syntax (compiler -z): SKIPPED (syntaxCheck=false)." ;;
    esac
    echo
    echo "Semantic rules: ${errs} error(s), ${warns} warning(s), ${infos} note(s)"
    echo "------------------------------------------------------------"
    if [[ -z "$(echo "$LINT_OUT" | tr -d '[:space:]')" ]]; then
        echo "No semantic findings."
    else
        local sev s ln rule msg
        for sev in error warn info; do
            while IFS='|' read -r s ln rule msg; do
                [[ "$s" != "$sev" ]] && continue
                printf '[%s] line %s (%s): %s\n' "$s" "$ln" "$rule" "$msg"
            done <<< "$LINT_OUT"
        done
    fi
    return 0
}
