#!/usr/bin/env bash
set -euo pipefail

########################################
# TUNABLES (override with env vars)
########################################
: "${OLLAMA_URL:=http://localhost:9090/proxy}"     # native API base (NOT /v1)
: "${MODEL_NAME:=llama3.2:3b}"                # ollama model name
: "${REQ_RATE:=24}"                            # target requests per second (approx)
: "${CONCURRENCY:=24}"                         # max in-flight requests
: "${MAX_TOKENS:=256}"                         # num_predict per request
: "${TOTAL_PROMPTS:=0}"                        # 0 = use all prompts; >0 = cap
: "${PROMPTS_FILE:=truthfulqa_prompts.txt}"    # extracted questions
: "${SRC_JSONL:=validation.jsonl}" # raw dataset dump
: "${LOG_FILE:=ollama_spam.log}"               # simple log of HTTP statuses
: "${HF_TOKEN:=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}"                            # Hugging Face token for private datasets

# Dataset source (TruthfulQA generation split / validation set)
# (If this ever changes, update URL or just provide your own PROMPTS_FILE.)
DATA_URL="https://huggingface.co/datasets/v-xchen-v/truthfulqa_true/blob/main/validation.jsonl"

########################################
# REQUIREMENTS CHECK
########################################
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need curl
need jq

#
########################################
# FETCH DATASET (once) & EXTRACT PROMPTS
########################################
if [[ ! -s "$SRC_JSONL" ]]; then
  echo "Downloading TruthfulQA (generation/validation) -> $SRC_JSONL"
    # replace the current curl that failed with:
    if [[ -n "${HF_TOKEN:-}" ]]; then
    curl -L --fail -H "Authorization: Bearer $HF_TOKEN" \
        -o "$SRC_JSONL" "$DATA_URL"
    else
    curl -L --fail -o "$SRC_JSONL" "$DATA_URL"
    fi
fi

if [[ ! -s "$PROMPTS_FILE" ]]; then
  echo "Extracting questions -> $PROMPTS_FILE"
  # Grab the 'question' field as plain lines
  jq -r '.question' "$SRC_JSONL" > "$PROMPTS_FILE"
fi

TOTAL_LINES=$(wc -l < "$PROMPTS_FILE" | tr -d ' ')
if [[ "${TOTAL_PROMPTS}" -gt 0 && "${TOTAL_PROMPTS}" -lt "${TOTAL_LINES}" ]]; then
  echo "Limiting prompts to first ${TOTAL_PROMPTS}/${TOTAL_LINES}"
  head -n "$TOTAL_PROMPTS" "$PROMPTS_FILE" > "${PROMPTS_FILE}.tmp"
  mv "${PROMPTS_FILE}.tmp" "$PROMPTS_FILE"
  TOTAL_LINES="$TOTAL_PROMPTS"
fi

echo "==> Ready to spam:"
echo "    OLLAMA_URL   = $OLLAMA_URL"
echo "    MODEL_NAME   = $MODEL_NAME"
echo "    REQ_RATE     = $REQ_RATE req/s"
echo "    CONCURRENCY  = $CONCURRENCY"
echo "    MAX_TOKENS   = $MAX_TOKENS"
echo "    PROMPTS      = $TOTAL_LINES lines in $PROMPTS_FILE"
echo

########################################
# SIMPLE SERVER REACHABILITY CHECK
########################################
if ! curl -sS -m 2 "$OLLAMA_URL/version" >/dev/null; then
  echo "WARNING: Cannot reach $OLLAMA_URL . Make sure Ollama is running and listening (e.g., OLLAMA_HOST=0.0.0.0)."
fi

########################################
# BASH SEMAPHORE FOR CONCURRENCY
########################################
# Create a named pipe semaphore with $CONCURRENCY tokens
SEM=/tmp/.$$."sem"
mkfifo "$SEM" || true
exec 3<>"$SEM"
rm "$SEM"
for _ in $(seq 1 "$CONCURRENCY"); do
  echo >&3
done

########################################
# RATE CONTROL
########################################
# Sleep between launches ~ 1/REQ_RATE seconds. If REQ_RATE==0, fire at will.
interval="0"
if [[ "$REQ_RATE" -gt 0 ]]; then
  # Use awk for floating sleeps portable across shells
  interval=$(awk -v r="$REQ_RATE" 'BEGIN{printf "%.6f", 1.0/r}')
fi

########################################
# REQUEST FUNCTION
########################################
send_one() {
  local prompt="$1"

  # JSON-escape the prompt as a string
  local prompt_json
  prompt_json=$(jq -Rn --arg p "$prompt" '$p')

  # Build the payload for /api/chat (native Ollama API)
  # NOTE: --argjson already parses JSON; DO NOT use |fromjson on $opts
  local payload
  payload=$(jq -n \
    --arg model "$MODEL_NAME" \
    --arg p "$prompt" \
    --argjson opts "{\"num_predict\": $MAX_TOKENS, \"temperature\": 0}" \
    '{
       model: $model,
       messages: [ { "role": "user", "content": $p } ],
       stream: false,
       options: $opts
     }')

  # Send request; log status code for sanity
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST "$OLLAMA_URL/api/chat" \
    --data "$payload" || echo "000")

  echo "$(date -Is) $http_code" >> "$LOG_FILE"
}


########################################
# MAIN LOOP: spawn with rate & concurrency
########################################
echo "Spamming... (CTRL+C to stop)"
trap 'echo; echo "Stopping..."; exit 0' INT

line_no=0
while IFS= read -r line; do
  # acquire a token
  read -r -u 3

  # spawn in background
  {
    send_one "$line"
    # release token
    echo >&3
  } &

  # basic rate control
  if [[ "$REQ_RATE" -gt 0 ]]; then
    awk -v s="$interval" 'BEGIN{ system("sleep " s) }' >/dev/null 2>&1
  fi

  line_no=$((line_no+1))
done < "$PROMPTS_FILE"

wait
echo "Done. Logged statuses to $LOG_FILE"
