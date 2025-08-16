#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG (override via env)
########################################
PROMPTS_FILE="${PROMPTS_FILE:-truthfulqa_prompts_repo.txt}"      # one prompt per line
MODEL="${MODEL:-llama3.2:3b}"
URL="${URL:-http://localhost:28080/proxy/api/generate}"      # your proxy/generate endpoint
REQUESTS="${REQUESTS:-300}"                                  # how many prompts to send
CONCURRENCY="${CONCURRENCY:-100}"                            # in-flight requests
MAX_TOKENS="${MAX_TOKENS:-256}"                             # generation length
POLL_INTERVAL="${POLL_INTERVAL:-1}"                         # seconds between replica polls
NAMESPACE="${NAMESPACE:-ollama}"                              # k8s namespace
DEPLOY="${DEPLOY:-ollama}"                                   # k8s deployment name
RUNS="${RUNS:-HPA_ON}"                                       # labels to run, space-separated

# Optional hooks to toggle HPA/state between runs (leave empty if manual)
# Example:
#   HOOK_BEFORE_HPA_ON='kubectl -n llm scale deploy/ollama --replicas=1 && kubectl -n llm scale hpa/ollama-hpa --replicas=1'
#   HOOK_BEFORE_HPA_OFF='kubectl -n llm delete hpa ollama-hpa --ignore-not-found=true && kubectl -n llm scale deploy/ollama --replicas=1'
declare -A HOOK_BEFORE
declare -A HOOK_AFTER
HOOK_BEFORE[HPA_ON]="${HOOK_BEFORE_HPA_ON:-}"
HOOK_AFTER[HPA_ON]="${HOOK_AFTER_HPA_ON:-}"
HOOK_BEFORE[HPA_OFF]="${HOOK_BEFORE_HPA_OFF:-}"
HOOK_AFTER[HPA_OFF]="${HOOK_AFTER_HPA_OFF:-}"

########################################
# DEPENDENCIES
########################################
for dep in jq curl kubectl date nl awk sed tr; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep"; exit 1; }
done
[[ -f "$PROMPTS_FILE" ]] || { echo "Prompts file not found: $PROMPTS_FILE"; exit 1; }

########################################
# HELPERS
########################################
now_iso() { date -Ins; }
ms_now() { date +%s%3N; }

poll_replicas() {
  local namespace="$1" deploy="$2" interval="$3" out_csv="$4"
  echo "timestamp,availableReplicas,readyReplicas" > "$out_csv"
  while true; do
    local ts ar rr
    ts=$(now_iso)
    ar=$(kubectl -n "$namespace" get deploy "$deploy" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")
    rr=$(kubectl -n "$namespace" get deploy "$deploy" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    echo "$ts,${ar:-0},${rr:-0}" >> "$out_csv"
    sleep "$interval"
  done
}

make_request() {
  # $1 prompt, $2 req_id, $3 url, $4 model, $5 max_tokens, $6 out_csv, $7 errors_file
  local prompt="$1" req_id="$2" url="$3" model="$4" max_tokens="$5" out_csv="$6" errors_file="$7"

  local prompt_json payload t0 t1 t0ms t1ms http_code tmpfile
  tmpfile="$(mktemp)"

  prompt_json=$(printf "%s" "$prompt" | jq -Rs .)
  payload=$(jq -n \
    --arg model "$model" \
    --argjson prompt "$prompt_json" \
    # --argjson max_tok "$max_tokens" \
    '{
      model: $model,
      prompt: $prompt,
      stream: false,
      options: { num_predict: $max_tok, temperature: 0 }
    }')

  t0=$(now_iso); t0ms=$(ms_now)
  http_code=$(curl -sS -w "%{http_code}" -o "$tmpfile" \
    -H "Content-Type: application/json" \
    -X POST "$url" \
    --data "$payload" \
    --max-time 180 || echo "000")
  t1=$(now_iso); t1ms=$(ms_now)
  local latency_ms=$((t1ms - t0ms))

  # defaults / parsed fields
  local p_tok="" c_tok="" t_tok="" evc="" ev_ms="" pev="" pev_ms="" tot_ms=""

  # Try OpenAI usage block
  p_tok=$(jq -r 'try .usage.prompt_tokens // empty' "$tmpfile")
  c_tok=$(jq -r 'try .usage.completion_tokens // empty' "$tmpfile")
  t_tok=$(jq -r 'try .usage.total_tokens // empty' "$tmpfile")

  # Try Ollama-native counters (ns -> ms)
  evc=$(jq -r 'try .eval_count // empty' "$tmpfile")
  pev=$(jq -r 'try .prompt_eval_count // empty' "$tmpfile")
  ev_ms=$(jq -r 'try (.eval_duration|tonumber/1000000) // empty' "$tmpfile")
  pev_ms=$(jq -r 'try (.prompt_eval_duration|tonumber/1000000) // empty' "$tmpfile")
  tot_ms=$(jq -r 'try (.total_duration|tonumber/1000000) // empty' "$tmpfile")

  if [[ "$http_code" != "200" ]]; then
    {
      echo "=== Request $req_id ==="
      echo "HTTP: $http_code"
      echo "Payload:"; echo "$payload"
      echo "Body:"; cat "$tmpfile"
      echo
    } >> "$errors_file"
  fi

  echo "$req_id,$t0,$t1,$latency_ms,$http_code,${p_tok:-},${c_tok:-},${t_tok:-},${evc:-},${ev_ms:-},${pev:-},${pev_ms:-},${tot_ms:-}" >> "$out_csv"

  rm -f "$tmpfile"
}

run_spammer() {
  # $1 prompts_file, $2 requests, $3 concurrency, $4 url, $5 model, $6 max_tokens, $7 out_csv, $8 errors_file
  local prompts_file="$1" requests="$2" concurrency="$3" url="$4" model="$5" max_tokens="$6" out_csv="$7" errors_file="$8"

  echo "request_id,start_iso,end_iso,latency_ms,http_code,prompt_tokens,completion_tokens,total_tokens,eval_count,eval_ms,prompt_eval_count,prompt_eval_ms,total_ms" > "$out_csv"
  : > "$errors_file"

  # numbered prompts (tab-separated)
  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  local num_file="$tmpdir/numbered.txt"
  head -n "$requests" "$prompts_file" | nl -nln > "$num_file"

  export -f make_request now_iso ms_now
  export url model max_tokens out_csv errors_file

  # null-safe fan-out (-0), pass req_id + prompt as args
  awk -F'\t' '{print $1"\0"$2"\0"}' "$num_file" | \
  xargs -0 -n2 -P"$concurrency" bash -c '
    req_id="$1"; prompt="$2"
    make_request "$prompt" "$req_id" "$url" "$model" "$max_tokens" "$out_csv" "$errors_file"
  ' --
}

run_one_label() {
  local label="$1" outdir="$2"

  echo "==== RUN: $label ===="
  [[ -n "${HOOK_BEFORE[$label]:-}" ]] && { echo ">> HOOK_BEFORE[$label]"; eval "${HOOK_BEFORE[$label]}"; }

  local req_csv="$outdir/${label}_requests.csv"
  local rep_csv="$outdir/${label}_replicas.csv"
  local err_log="$outdir/${label}_errors.log"
  mkdir -p "$outdir"

  # start poller
  poll_replicas "$NAMESPACE" "$DEPLOY" "$POLL_INTERVAL" "$rep_csv" &
  local poll_pid=$!
  echo "Polling replicas (PID: $poll_pid) -> $rep_csv"

  # spam
  run_spammer "$PROMPTS_FILE" "$REQUESTS" "$CONCURRENCY" "$URL" "$MODEL" "$MAX_TOKENS" "$req_csv" "$err_log"

  # stop poller
  kill "$poll_pid" 2>/dev/null || true
  wait "$poll_pid" 2>/dev/null || true

  [[ -n "${HOOK_AFTER[$label]:-}" ]] && { echo ">> HOOK_AFTER[$label]"; eval "${HOOK_AFTER[$label]}"; }

  echo "Done: $label → $req_csv , $rep_csv"
}

main() {
  local stamp; stamp=$(date +"%Y%m%d_%H%M%S")
  local root="out_${stamp}"
  mkdir -p "$root"

  echo "Prompts: $PROMPTS_FILE"
  echo "URL:     $URL"
  echo "Model:   $MODEL"
  echo "Reqs:    $REQUESTS   Concurrency: $CONCURRENCY   MaxTokens: $MAX_TOKENS"
  echo "Namespace/Deploy: $NAMESPACE / $DEPLOY"
  echo "Runs:    $RUNS"
  echo "Output root: $root"
  echo

  for label in $RUNS; do
    run_one_label "$label" "$root"
  done

  echo
  echo "All runs complete. Outputs under: $root"
  echo "CSV files generated:"
  find "$root" -type f -name "*.csv" -maxdepth 2 -print | sed 's/^/  - /'
}

main "$@"
