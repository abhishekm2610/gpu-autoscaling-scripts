#!/usr/bin/env bash
# parallel_requests.sh
# Usage: ./parallel_requests.sh [prompts_file] [max_concurrent]

PROMPTS_FILE="${1:-truthfulqa_prompts_repo.txt}"
MAX_CONCURRENT="${2:-100}"
MODEL="llama3.2:3b"
URL="http://localhost:9090/proxy"
LOGFILE="parallel_outputs.log"
ERRORS_FILE="parallel_errors.log"

# Check dependencies
if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    exit 1
fi

if [[ ! -f "$PROMPTS_FILE" ]]; then
    echo "Prompts file not found: $PROMPTS_FILE"
    exit 1
fi

# Initialize log files
: > "$LOGFILE"
: > "$ERRORS_FILE"

echo "==> Starting parallel requests"
echo "    Prompts file: $PROMPTS_FILE"
echo "    Max concurrent: $MAX_CONCURRENT"
echo "    Model: $MODEL"
echo "    URL: $URL"
echo "    Output log: $LOGFILE"
echo "    Error log: $ERRORS_FILE"
echo ""

# Function to send a single request
send_request() {
    local prompt="$1"
    local id="$2"

    # Create JSON payload
    local json_payload=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            prompt: $prompt,
            stream: false
        }')

    echo "[$id] Sending: ${prompt:0:60}..."

    # Send request and capture response
    local response=$(curl -s -w "\n%{http_code}" -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        --max-time 120 \
        --retry 2 \
        --retry-delay 3)

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" ]]; then
        echo "[$id] ✓ Success"
        {
            echo "=== Request $id ==="
            echo "Prompt: $prompt"
            echo "Response:"
            echo "$body" | jq -r '.response // .choices[0].message.content // .' 2>/dev/null || echo "$body"
            echo ""
        } >> "$LOGFILE"
    else
        echo "[$id] ✗ Failed (HTTP: $http_code)"
        {
            echo "=== Error $id ==="
            echo "Prompt: $prompt"
            echo "HTTP Code: $http_code"
            echo "Response: $body"
            echo ""
        } >> "$ERRORS_FILE"
    fi
}

# Export function for use in subshells
export -f send_request
export MODEL URL LOGFILE ERRORS_FILE

# Read prompts and send requests in parallel
total_prompts=$(wc -l < "$PROMPTS_FILE")
echo "Total prompts to process: $total_prompts"
echo ""

# Use cat with line numbers and xargs for parallel execution
cat -n "$PROMPTS_FILE" | \
xargs -I {} -P "$MAX_CONCURRENT" bash -c '
    line="{}"
    id=$(echo "$line" | cut -f1)
    prompt=$(echo "$line" | cut -f2-)
    send_request "$prompt" "$id"
'

# Wait for all background processes to complete
wait

echo ""
echo "==> All requests completed!"

# Show summary
successful_requests=$(grep -c "^=== Request" "$LOGFILE" 2>/dev/null || echo 0)
failed_requests=$(grep -c "^=== Error" "$ERRORS_FILE" 2>/dev/null || echo 0)

echo "==> Summary:"
echo "    Total prompts: $total_prompts"
echo "    Successful: $successful_requests"
echo "    Failed: $failed_requests"
echo "    Success rate: $(( successful_requests * 100 / total_prompts ))%"
echo ""
echo "    Response log: $LOGFILE"
echo "    Error log: $ERRORS_FILE"

if [[ $failed_requests -gt 0 ]]; then
    echo ""
    echo "Check $ERRORS_FILE for details about failed requests."
fi
