#!/usr/bin/env bash
# spam_prompts.sh
# Usage: ./spam_prompts.sh prompts.txt

PROMPTS_FILE="${1:-truthfulqa_prompts_repo.txt}"
MODEL="llama3.2:3b"
URL="http://localhost:18080/proxy/api/generate"
CONCURRENCY=100
REQUESTS=500
LOGFILE="spam_outputs.log"
TEMP_DIR=$(mktemp -d)
ERRORS_FILE="spam_errors.log"

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed. Please install curl first."
    exit 1
fi

if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "Prompts file not found: $PROMPTS_FILE"
  exit 1
fi

echo "==> Sending $REQUESTS requests with $CONCURRENCY concurrency"
echo "    Model: $MODEL"
echo "    URL:   $URL"
echo "    Prompts from: $PROMPTS_FILE"
echo "    Logging to: $LOGFILE"
echo "    Errors to: $ERRORS_FILE"
echo "    Temp directory: $TEMP_DIR"

# Initialize log files
: > "$LOGFILE"
: > "$ERRORS_FILE"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Function to make a single request
make_request() {
    local prompt="$1"
    local request_id="$2"
    local temp_file="$TEMP_DIR/response_$request_id.json"
    local error_file="$TEMP_DIR/error_$request_id.log"

    echo "[$request_id] Processing: ${prompt:0:50}..."

    # Create API payload (works for both Ollama and proxy)
    local json_payload
    json_payload=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            prompt: $prompt,
            stream: false
        }')

    # Make the request with proper error handling
    local http_code
    http_code=$(curl -s -w "%{http_code}" -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        --max-time 120 \
        --retry 2 \
        --retry-delay 5 \
        -o "$temp_file" 2>"$error_file")

    if [[ "$http_code" == "200" ]]; then
        echo "[$request_id] ✓ Request completed successfully"
        return 0
    else
        echo "[$request_id] ✗ Request failed (HTTP: $http_code)" >&2
        {
            echo "=== Error for Request $request_id ==="
            echo "Prompt: $prompt"
            echo "HTTP Code: $http_code"
            echo "Error details:"
            cat "$error_file" 2>/dev/null
            echo "Response:"
            cat "$temp_file" 2>/dev/null
            echo ""
        } >> "$ERRORS_FILE"
        return 1
    fi
}

export -f make_request
export URL MODEL TEMP_DIR ERRORS_FILE LOGFILE

# Send requests concurrently using xargs with proper quote handling
echo "Starting concurrent execution..."
echo "Press Ctrl+C to stop at any time"

# Create a temporary file with numbered prompts to avoid quote issues
temp_prompts_file="$TEMP_DIR/numbered_prompts.txt"
head -n "$REQUESTS" "$PROMPTS_FILE" | nl -nln > "$temp_prompts_file"

# Use xargs with -0 option and printf to handle special characters safely
cat "$temp_prompts_file" | while IFS=$'\t' read -r request_id prompt; do
    printf '%s\0%s\0' "$request_id" "$prompt"
done | xargs -0 -n2 -P"$CONCURRENCY" bash -c '
    request_id="$1"
    prompt="$2"
    make_request "$prompt" "$request_id"
' --

echo "==> All requests completed!"

# Combine all responses into the main log file
echo "Combining responses..."
for file in "$TEMP_DIR"/response_*.json; do
    if [[ -f "$file" ]]; then
        request_id=$(basename "$file" .json | sed 's/response_//')
        # Get the corresponding prompt
        prompt=$(sed -n "${request_id}p" "$PROMPTS_FILE")

        {
            echo "=== Request $request_id ==="
            echo "Prompt: $prompt"
            echo "Response:"
            jq -r '.response // .choices[0].message.content // "No response field found"' "$file" 2>/dev/null || cat "$file"
            echo ""
        } >> "$LOGFILE"
    fi
done

# Show summary
total_responses=$(find "$TEMP_DIR" -name "response_*.json" -type f | wc -l)
total_errors=$(wc -l < "$ERRORS_FILE" 2>/dev/null || echo 0)

echo "==> Summary:"
echo "    Total requests sent: $REQUESTS"
echo "    Successful responses: $total_responses"
echo "    Failed requests: $((REQUESTS - total_responses))"
echo "    Response log: $LOGFILE"
echo "    Error log: $ERRORS_FILE"

if [[ $total_errors -gt 0 ]]; then
    echo ""
    echo "Check $ERRORS_FILE for details about failed requests."
fi