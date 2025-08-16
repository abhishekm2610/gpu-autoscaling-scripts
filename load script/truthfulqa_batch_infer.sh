#!/bin/bash

# File containing prompts (one per line)
PROMPT_FILE="truthfulqa_prompts_repo.txt"
# Ollama-compatible LLM inference server endpoint
ENDPOINT="http://localhost:18080/proxy/api/generate"

# Output CSV file
OUTFILE="inference_results.csv"

echo "prompt,time_seconds,output_tokens" > "$OUTFILE"

while IFS= read -r prompt || [ -n "$prompt" ]; do
    # Skip empty lines
    if [[ -z "$prompt" ]]; then
        continue
    fi

    # Start time
    start=$(date +%s.%N)

    # Send prompt (no streaming) and get response
    response=$(curl -s -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "{\"model\": \"llama3.2\", \"prompt\": \"${prompt}\", \"stream\": false}")

    # End time
    end=$(date +%s.%N)
    elapsed=$(echo "$end - $start" | bc)

    # Parse output tokens (eval_count) using jq
    tokens=$(echo "$response" | jq '.eval_count // empty')
    # If jq not installed, fallback to grep/sed:
    # tokens=$(echo "$response" | grep -o '"eval_count":[0-9]*' | head -1 | sed 's/[^0-9]*//')

    # Output CSV
    # Escape double-quotes in prompt
    esc_prompt=$(echo "$prompt" | sed 's/"/""/g')
    echo "\"$esc_prompt\",$elapsed,$tokens" >> "$OUTFILE"

    # Optional: progress indicator
    echo "Prompt completed in $elapsed s, tokens: $tokens"
done < "$PROMPT_FILE"