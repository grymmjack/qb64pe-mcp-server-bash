#!/bin/bash
# qb64pe_mcp_server.sh — lean QB64PE MCP server (bash edition).
# Wires the vendored MCP core to the QB64PE tool implementations in lib/.
#
# Tools: wiki_page, wiki_search, keyword_lookup, lint, inject_logging, compile, run, screenshot
# Requires: bash, jq, curl (wiki); optional: qb64pe (lint/compile), xdotool + ImageMagick (run/screenshot).

QB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QB_DATA="$QB_ROOT/data"

# Override the core's config paths BEFORE sourcing it.
MCP_CONFIG_FILE="$QB_ROOT/assets/qb64pe_config.json"
MCP_TOOLS_LIST_FILE="$QB_ROOT/assets/qb64pe_tools.json"
MCP_LOG_FILE="$QB_ROOT/logs/qb64pe-mcp.log"

# Core MCP protocol (JSON-RPC over stdio). Patched copy: newline-flatten removed.
source "$QB_ROOT/mcpserver_core.sh"

# Shared helpers first, then the tool implementations.
source "$QB_ROOT/lib/common.sh"
source "$QB_ROOT/lib/platform.sh"   # OS abstraction (launch/teardown/window/capture/pty) + tool_doctor
source "$QB_ROOT/lib/docs.sh"
source "$QB_ROOT/lib/lint.sh"
source "$QB_ROOT/lib/logging.sh"
source "$QB_ROOT/lib/compile.sh"

run_mcp_server "$@"
