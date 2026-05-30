#!/bin/bash
# docs.sh — QB64PE documentation tools: wiki_page, wiki_search, keyword_lookup
# Sourced by qb64pe_mcp_server.sh after mcpserver_core.sh. Uses $QB_ROOT and $QB_DATA.

QB_WIKI_BASE="https://qb64phoenix.com/qb64wiki"
QB_WIKI_API="$QB_WIKI_BASE/api.php"
QB_WIKI_PAGE="$QB_WIKI_BASE/index.php"

# Wiki source occasionally contains stray control bytes that MediaWiki echoes
# unescaped inside JSON string values; jq (strict) then rejects the whole response.
# Strip the illegal-in-JSON control chars (keep TAB 0x09, LF 0x0A, CR 0x0D).
_qb_strip_ctrl() { tr -d '\000-\010\013\014\016-\037'; }

# tool_wiki_page — fetch the COMPLETE wiki page (raw wikitext) for a keyword/topic.
# Returning raw wikitext is the structural fix for the old HTML-scraper bug that
# dropped Syntax/Parameters/Description sections.
tool_wiki_page() {
    local args="$1"
    local page
    page=$(echo "$args" | jq -r '.page // empty')
    if [[ -z "$page" ]]; then
        echo "Missing required parameter: page"
        return 1
    fi

    if ! command -v curl &>/dev/null; then
        echo "curl is required for wiki_page but is not installed."
        return 1
    fi

    # MediaWiki titles use spaces internally; URLs use underscores. The API 'page'
    # param accepts either when URL-encoded. Try the title verbatim, then a
    # spaces<->underscores variant before giving up.
    local resp wikitext title try
    for try in "$page" "${page//_/ }" "${page// /_}"; do
        resp=$(curl -sS --max-time 20 -G "$QB_WIKI_API" \
            --data-urlencode "action=parse" \
            --data-urlencode "page=$try" \
            --data-urlencode "prop=wikitext" \
            --data-urlencode "redirects=1" \
            --data-urlencode "format=json" 2>/dev/null | _qb_strip_ctrl)
        [[ -z "$resp" ]] && continue
        # Bail out of the loop the moment we get a real page
        if echo "$resp" | jq -e '.parse.wikitext' >/dev/null 2>&1; then
            title=$(echo "$resp" | jq -r '.parse.title // empty')
            wikitext=$(echo "$resp" | jq -r '.parse.wikitext."*" // empty')
            break
        fi
    done

    if [[ -z "$wikitext" ]]; then
        local url="$QB_WIKI_PAGE/${page// /_}"
        echo "No wiki page found for '$page'. Try wiki_search to find the right title, or open: $url"
        return 0
    fi

    local url="$QB_WIKI_PAGE/${title// /_}"
    # Strip any stray control bytes from the emitted content so the MCP core's
    # stringification always produces valid JSON, regardless of wiki source quirks.
    printf '# %s\n<%s>\n\n(Complete raw wikitext — all sections, including Syntax/Parameters/Description.)\n\n%s\n' \
        "$title" "$url" "$wikitext" | _qb_strip_ctrl
    return 0
}

# Offline keyword-DB search program (jq). Tokenizes the query on non-word chars
# but KEEPS underscores, so '_MOUSEBUTTON' stays one token (exact-name match)
# while 'mouse input' splits in two. Scores name/desc/alias/tag/related hits and
# returns the top $limit as a JSON array of {name,type,description}.
_QB_LOCAL_SEARCH_JQ='
def hay:
  ((.name // "") + " " + (.description // "") + " "
   + ((.aliases // []) | join(" ")) + " " + (.category // "") + " "
   + ((.tags // []) | join(" ")) + " " + ((.related // []) | join(" ")))
  | ascii_downcase;
($q | ascii_downcase) as $ql
| ($ql | [splits("[^a-z0-9_]+")] | map(select(length > 0))) as $toks
| [ .keywords[]
    | . as $e
    | ($e | hay) as $h
    | (($e.name // "") | ascii_downcase) as $n
    | ([ $toks[] as $tok | select($h | contains($tok)) ] | length) as $hits
    | select($hits > 0)
    | { name: ($e.name // ""), type: ($e.type // ""), description: ($e.description // ""),
        score: ( $hits
                 + (if $n == $ql then 1000 else 0 end)
                 + (if ($ql | length) > 0 and ($n | contains($ql)) then 100 else 0 end)
                 + (if ($h | contains($ql)) then 30 else 0 end)
                 + (([ $toks[] as $tok | select($n | contains($tok)) ] | length) * 10) ) } ]
| sort_by([ (-.score), .name ]) | .[0:$limit] | map(del(.score))
'

# tool_wiki_search — find matching QB64PE pages. PRIMARY index is the bundled
# offline keyword DB (reliable for underscore/multi-word terms the wiki full-text
# search chokes on); the network is a best-effort supplement that never blocks
# the offline hit. Returns matching keyword/page titles with URLs.
tool_wiki_search() {
    local args="$1"
    local query limit
    query=$(echo "$args" | jq -r '.query // empty')
    limit=$(echo "$args" | jq -r '.limit // 10')
    if [[ -z "$query" ]]; then
        echo "Missing required parameter: query"
        return 1
    fi
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=10

    # 1) Offline keyword-DB search (works with no network; the dependable path).
    local db="$QB_DATA/keywords.json" local_json="[]"
    if [[ -f "$db" ]]; then
        local_json=$(jq -c --arg q "$query" --argjson limit "$limit" "$_QB_LOCAL_SEARCH_JQ" "$db" 2>/dev/null)
        [[ -z "$local_json" ]] && local_json="[]"
    fi

    # 2) Remote full-text (list=search) + title/prefix (opensearch), best-effort.
    local remote_json="[]"
    if command -v curl &>/dev/null; then
        local r1 r2 a b
        r1=$(curl -sS --max-time 15 -G "$QB_WIKI_API" \
            --data-urlencode "action=query" --data-urlencode "list=search" \
            --data-urlencode "srsearch=$query" --data-urlencode "srlimit=$limit" \
            --data-urlencode "format=json" 2>/dev/null | _qb_strip_ctrl)
        r2=$(curl -sS --max-time 15 -G "$QB_WIKI_API" \
            --data-urlencode "action=opensearch" --data-urlencode "search=$query" \
            --data-urlencode "limit=$limit" --data-urlencode "format=json" 2>/dev/null | _qb_strip_ctrl)
        a=$(echo "$r1" | jq -c '[.query.search[]?.title]' 2>/dev/null); [[ -z "$a" ]] && a="[]"
        b=$(echo "$r2" | jq -c '(.[1] // [])' 2>/dev/null);            [[ -z "$b" ]] && b="[]"
        remote_json=$(jq -nc --argjson a "$a" --argjson b "$b" '($a + $b) | unique' 2>/dev/null)
        [[ -z "$remote_json" ]] && remote_json="[]"
    fi

    local lc rc
    lc=$(echo "$local_json"  | jq 'length' 2>/dev/null); [[ "$lc" =~ ^[0-9]+$ ]] || lc=0
    rc=$(echo "$remote_json" | jq 'length' 2>/dev/null); [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
    if [[ "$lc" -eq 0 && "$rc" -eq 0 ]]; then
        echo "No results for \"$query\". Try a single keyword (e.g. _MOUSEINPUT) or wiki_page \"$query\"."
        return 0
    fi

    # Merge: offline hits first, then remote titles not already covered (dedup
    # case-insensitively), formatted into a readable list.
    jq -rn \
        --argjson loc "$local_json" --argjson rem "$remote_json" \
        --arg q "$query" --arg base "$QB_WIKI_PAGE" --argjson limit "$limit" '
        ($loc | map(.name | ascii_downcase)) as $haveLC
        | ($rem | map(select((. | ascii_downcase) as $t | ($haveLC | index($t)) == null)) | .[0:$limit]) as $remOnly
        | ( [ "QB64PE search results for \"\($q)\":", "" ]
            + (if ($loc | length) > 0 then
                 [ "From the offline keyword database (most relevant):" ]
                 + [ $loc[] | "- \(.name)\(if (.type // "") != "" then " [\(.type)]" else "" end)\(if (.description // "") != "" then " — \(.description)" else "" end)\n  \($base)/\((.name) | gsub(" "; "_"))" ]
               else [] end)
            + (if ($remOnly | length) > 0 then
                 [ "", "From the wiki full-text search:" ]
                 + [ $remOnly[] | "- \(.)\n  \($base)/\((.) | gsub(" "; "_"))" ]
               else [] end)
          ) | .[]'
    return 0
}

# tool_keyword_lookup — fast offline lookup from the bundled keyword DB.
tool_keyword_lookup() {
    local args="$1"
    local kw
    kw=$(echo "$args" | jq -r '.keyword // empty')
    if [[ -z "$kw" ]]; then
        echo "Missing required parameter: keyword"
        return 1
    fi

    local db="$QB_DATA/keywords.json"
    if [[ ! -f "$db" ]]; then
        echo "Keyword database not found at $db"
        return 1
    fi

    # Exact key first, then case-insensitive match across all keys.
    local entry
    entry=$(jq --arg k "$kw" '
        .keywords as $kws
        | ($kws[$k])
          // ([ $kws | to_entries[] | select((.key|ascii_downcase) == ($k|ascii_downcase)) | .value ][0])
        // empty
    ' "$db")

    if [[ -z "$entry" || "$entry" == "null" ]]; then
        echo "No exact match for '$kw' in the offline DB. Try wiki_search \"$kw\" or wiki_page \"$kw\"."
        return 0
    fi

    echo "$entry" | jq -r --arg base "$QB_WIKI_PAGE" '
        "Keyword: \(.name)",
        "Type: \(.type // "n/a")   Category: \(.category // "n/a")",
        "Availability: \(.availability // "n/a")   Version: \(.version // "n/a")",
        "",
        "Syntax:",
        "  \(.syntax // "n/a")",
        "",
        "Description:",
        "  \(.description // "n/a")",
        (if (.example // "") != "" then "\nExample:\n\(.example)" else empty end),
        (if (.related // [] | length) > 0 then "\nRelated: \(.related | join(", "))" else empty end),
        "\nFull docs: \($base)/\(.name|gsub(" ";"_"))",
        "(Use wiki_page \"\(.name)\" for the complete page.)"
    '
    return 0
}
