# selfref.awk — detect the QB64PE FUNCTION self-reference SIGSEGV trap.
# Inside FUNCTION foo%, reading foo% in an expression is a RECURSIVE CALL, not a
# variable read; only `foo% = <expr>` sets the return value. Any other read of the
# function's own name triggers infinite recursion -> stack overflow / SIGSEGV.
# Output (TAB-separated): <lineNo> <token> <stripped line>
# Portable across gawk/mawk: everything is matched in UPPERCASE (BASIC identifiers
# are case-insensitive), using only 2-arg match() and gsub() counting.
function esc(s,   r){ r=s; gsub(/[][(){}.^$*+?|\\\/]/, "\\\\&", r); return r }
{
    raw = $0
    # Strip a trailing apostrophe comment that is outside a double-quoted string.
    line = raw; inq = 0; cut = 0; n = length(raw)
    for (i = 1; i <= n; i++) {
        c = substr(raw, i, 1)
        if (c == "\"") inq = !inq
        else if (c == "'" && inq == 0) { cut = i; break }
    }
    if (cut > 0) line = substr(raw, 1, cut - 1)
    U = toupper(line)

    if (infunc == 0) {
        if (U ~ /^[ \t]*FUNCTION[ \t]+[A-Z_]/) {
            s = U; sub(/^[ \t]*FUNCTION[ \t]+/, "", s)
            if (match(s, /^[A-Z_][A-Z0-9_]*[%&!#~$`]*/)) {
                token = substr(s, 1, RLENGTH); infunc = 1
            }
        }
        next
    }
    if (U ~ /^[ \t]*END[ \t]+FUNCTION([ \t]|$)/) { infunc = 0; next }
    if (U ~ /^[ \t]*$/) next
    if (U ~ /^[ \t]*REM([ \t]|$)/) next

    et = esc(token)
    bre = "(^|[^A-Z0-9_])" et "([^A-Z0-9_%&!#~$`]|$)"
    tmp = U; cnt = gsub(bre, "&", tmp)
    if (cnt == 0) next

    assignLHS  = (U ~ ("^[ \t]*(LET[ \t]+)?" et "[ \t]*=([^=]|$)"))
    thenAssign = (U ~ ("THEN[ \t]+" et "[ \t]*=([^=]|$)"))
    if (cnt == 1 && (assignLHS || thenAssign)) next   # pure return-value assignment: safe

    disp = line; sub(/^[ \t]+/, "", disp)
    printf "%d\t%s\t%s\n", NR, token, disp
}
