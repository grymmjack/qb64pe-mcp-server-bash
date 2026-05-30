#!/bin/bash
# mcpserver_core.sh - Core # Function simplified - removed authorized tool list checking as it's from library Protocol) server implementation
# Handles JSON-RPC 2.0 messaging and MCP protocol infrastructure

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration paths - overridable by implementations
MCP_CONFIG_FILE="${MCP_CONFIG_FILE:-"$SCRIPT_DIR/assets/mcpserverconfig.json"}"
MCP_TOOLS_LIST_FILE="${MCP_TOOLS_LIST_FILE:-"$SCRIPT_DIR/assets/tools_list.json"}"
MCP_LOG_FILE="${MCP_LOG_FILE:-"$SCRIPT_DIR/mcpserver.log"}"

# Function to log messages to file
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Create logs directory if it doesn't exist
    mkdir -p "$(dirname "$MCP_LOG_FILE")"

    # Append log message to log file
    echo "[$timestamp] [$level] $message" >>"$MCP_LOG_FILE"
}

# Function to read a JSON file and convert it to a single line
read_json_file() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        # Read the file and remove all newlines and unnecessary whitespace
        jq -c '.' "$file_path"
    else
        echo "{\"error\": \"File not found: $file_path\"}" | jq -c '.'
    fi
}

# Function simplified - removed authorized tool list checking as it's from library

# ==== MCP Protocol Core Implementation ====

# Function to handle MCP initialize method
handle_initialize() {
    local id="$1"
    local params="$2"

    # Parse client info and capabilities from params
    local client_info=$(echo "$params" | jq '.clientInfo')
    local client_capabilities=$(echo "$params" | jq '.capabilities')
    local client_protocol_version=$(echo "$params" | jq -r '.protocolVersion')

    # Use the configuration from the specified config file
    local result=$(read_json_file "$MCP_CONFIG_FILE")

    create_response "$id" "$result" ""
}

# Function to list available tools
handle_tools_list() {
    local id="$1"

    # Read tools list from JSON file
    local result=$(read_json_file "$MCP_TOOLS_LIST_FILE")
    create_response "$id" "$result" ""
}

# Function to handle tool calls - delegates to tool implementations
handle_tools_call() {
    local id="$1"
    local params="$2"

    local tool_name=$(echo "$params" | jq -r '.name')
    local arguments=$(echo "$params" | jq '.arguments // {}')
    local result error content

    # Log the tool being called
    log "INFO" "Tool call: $tool_name with arguments: $(echo "$arguments" | jq -c '.')"

    # Validate tool name format (alphanumeric and underscores only)
    if ! [[ "$tool_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        create_error_response "$id" -32600 "Invalid tool name format"
        return
    fi

    # Call the function from the main script if it exists
    if type "tool_${tool_name}" &>/dev/null; then
        # Call the specific tool function from main script
        content=$(tool_${tool_name} "$arguments")

        # Check if we got an error
        if [[ $? -ne 0 ]]; then
            # Simple error handling - use the content as error message if available
            local error_message="Tool execution error"
            if [[ -n "$content" && "$content" != "null" ]]; then
                # Use the tool's output as the error message
                error_message="$error_message : $content"
            fi
            log "ERROR" "Tool $tool_name execution failed: $error_message"
            create_error_response "$id" -32603 "$error_message"
            return
        fi

    else
        # Read error template for unknown tool
        create_error_response "$id" -32601 "Tool not found: $tool_name"
        return
    fi

    # Use jq to escape the string
    stringified_content=$(echo "$content" | jq -R -s '.')

    # Then build the response structure with the stringified content
    result="{
        \"content\": [{
            \"type\": \"text\",
            \"text\": $stringified_content
        }]
    }"

    create_response "$id" "$result" ""
}

# ==== JSON-RPC 2.0 Handler ====

# Function to create a JSON-RPC 2.0 response
create_response() {
    local id="$1"
    local result="$2"
    local error="$3"
    local response

    if [[ -n "$error" ]]; then
        response="{\"jsonrpc\": \"2.0\", \"error\": $error, \"id\": $id}"
    else
        response="{\"jsonrpc\": \"2.0\", \"result\": $result, \"id\": $id}"
    fi

    # Ensure the response is properly formatted as a single line JSON with no newlines
    local formatted_response=$(echo "$response" | jq -c '.')

    # Log the response
    log "RESPONSE" "$formatted_response"

    # Output the response
    echo "$formatted_response"
}

# Function to create a JSON-RPC 2.0 error
create_error_response() {

    local id="$1"
    local code="$2"
    local errorMessage="$3"
    # jq-escape the message: error strings can contain newlines/quotes/backslashes
    # (e.g. a multi-line precondition error), which raw interpolation would turn
    # into malformed JSON. `jq -R -s '.'` yields a quoted, fully-escaped string.
    local escaped; escaped=$(printf '%s' "$errorMessage" | jq -R -s '.')
    local message="{\"code\": $code, \"message\": $escaped}"
    log "ERROR" "$message"

    create_response "$id" "null" "$message"

}

# Function to handle notification events (non-responsive)
handle_notification() {
    local method="$1"

    # Process notifications that don't require a response
    case "$method" in
    "notifications/initialized")
        log "INFO" "Host confirmed toolContract reception with 'notifications/initialized'"
        return 0 # Notification handled
        ;;
    # Add other notification types here
    *)
        return 1 # Not a notification
        ;;
    esac
}

# Function to process a JSON-RPC 2.0 request
process_request() {
    local input="$1"
    local jsonrpc version id method params result error

    # First check if message can be ignored
    if [[ -z "$input" ]]; then
        return 0 # Empty message, nothing to output
    fi

    # Log the input for processing
    log "REQUEST" "$input"

    # Parse the JSON-RPC 2.0 request
    jsonrpc=$(echo "$input" | jq -r '.jsonrpc')
    # Extract the ID exactly as received, preserving its format (string, number, null)
    id=$(echo "$input" | jq -c '.id')
    method=$(echo "$input" | jq -r '.method')

    # Log the method being called
    log "INFO" "Processing method: $method (id: $id)"

    # Validate JSON-RPC 2.0 version
    if [[ "$jsonrpc" != "2.0" ]]; then
        create_error_response "$id" -32600 "Invalid Request: Not a JSON-RPC 2.0 request"
        return
    fi

    # Check if this is a notification event (non-responsive)
    if handle_notification "$method"; then
        return 0 # Notification handled, no response needed
    fi

    params=$(echo "$input" | jq '.params')

    # Process the method
    case "$method" in
    # MCP Protocol Methods
    "initialize")
        handle_initialize "$id" "$params"
        ;;
    "tools/list")
        handle_tools_list "$id"
        ;;
    "tools/call")
        handle_tools_call "$id" "$params"
        ;;
    *)
        create_error_response "$id" -32601 "Method not found: $method"
        ;;
    esac
}

# === MCP Error Code Conventions ===
#
# Standard JSON-RPC error codes:
#  -32700: Parse error - Invalid JSON
#  -32600: Invalid Request - The JSON sent is not a valid Request object
#  -32601: Method not found - The method does not exist / is not available
#  -32602: Invalid params - Invalid method parameters
#  -32603: Internal error - Internal JSON-RPC error
#
# MCP-specific error codes:
#  -32000 to -32099: Server error - Reserved for implementation-defined server-errors
#
# Tool-specific error codes:
#   4000-4999: General client errors (equivalent to HTTP 4xx)
#   5000-5999: Server-side errors (equivalent to HTTP 5xx)
#   For example:
#     4001: Authentication required
#     4004: Resource not found
#     5001: Database error
#     5002: External service error

# ==== Main execution ====
run_mcp_server() {
    # Check if we have jq installed
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed. Install it using: brew install jq" >&2
        exit 1
    fi

    # Continuously read from stdin line by line
    log "INFO" "MCP Server started. Waiting for JSON-RPC 2.0 messages..."

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Process the JSON-RPC 2.0 request
        response=$(process_request "$line")

        # Output the response if not empty
        if [[ -n "$response" ]]; then
            echo "$response"
        fi
    done
}
