#!/usr/bin/env bash
set -euo pipefail

#####################################
# CONFIG — tweak these as you like
#####################################
# Ollama endpoint (native API, NOT OpenAI shim)
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"

# Load shape
REQ_RATE="${REQ_RATE:-12}"          # target requests/sec (Poisson-ish)
CONCURRENCY="${CONCURRENCY:-24}"    # max in-flight requests
MAX_TOKENS="${MAX_TOKENS:-128}"     # per-request generation cap
DURATION_SEC="${DURATION_SEC:-0}"   # 0 = consume all prompts once; >0 = run for N seconds

# Dataset/prompts
PROMPT_FILE="${PROMPT_FILE:-truthfulqa_prompts.jsonl}" # will be created if missing
RESULT_FILE="${RESULT_FILE:-ollama_bench_truthfulqa_results.json}"
LOG_FILE="${LOG_FILE:-ollama_bench_truthfulqa.log}"

#####################################
# 1) deps
#####################################
echo "==> Installing Python deps (datasets, aiohttp, numpy)..."
python3 -m pip install --upgrade pip >/dev/null
python3 -m pip -q install datasets aiohttp numpy >/dev/null

#####################################
# 2) build TruthfulQA prompts if absent
#####################################
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "==> Creating $PROMPT_FILE from TruthfulQA (generation split)..."
  python3 - <<'PY'
from datasets import load_dataset
import json, sys
out = sys.argv[1] if len(sys.argv) > 1 else "truthfulqa_prompts.jsonl"
ds = load_dataset("truthful_qa", "generation")
qs = ds["validation"]["question"]  # 817 questions
with open(out, "w") as f:
    for q in qs:
        # Minimal user prompt; model instructed to be concise & truthful
        messages = [{"role":"user","content": f"Answer truthfully and concisely:\n\nQuestion: {q}\nAnswer:"}]
        f.write(json.dumps({"messages": messages}) + "\n")
print(f"Wrote {len(qs)} prompts to {out}")
PY
  "$PROMPT_FILE"
else
  echo "==> Using existing $PROMPT_FILE"
fi

PROMPTS_COUNT=$(wc -l < "$PROMPT_FILE" | tr -d ' ')
echo "==> Prompts available: $PROMPTS_COUNT"

#####################################
# 3) quick reachability check
#####################################
echo "==> Checking Ollama at $OLLAMA_URL ..."
if ! curl -sS -m 2 "$OLLAMA_URL/version" >/dev/null; then
  echo "WARNING: Could not reach $OLLAMA_URL. Make sure Ollama is running and bound (e.g. OLLAMA_HOST=0.0.0.0)."
fi

#####################################
# 4) run asyncio load generator
#####################################
echo "==> Starting load: rate=${REQ_RATE}/s, concurrency=${CONCURRENCY}, max_tokens=${MAX_TOKENS}, duration=${DURATION_SEC}s (0=consume all once)"
python3 - <<'PY' "$OLLAMA_URL" "$MODEL_NAME" "$PROMPT_FILE" "$RESULT_FILE" "$REQ_RATE" "$CONCURRENCY" "$MAX_TOKENS" "$DURATION_SEC" | tee "$LOG_FILE"
import asyncio, aiohttp, json, time, math, random, sys, statistics, numpy as np
from pathlib import Path
from datetime import datetime

OLLAMA_URL, MODEL_NAME, PROMPT_FILE, RESULT_FILE, REQ_RATE, CONCURRENCY, MAX_TOKENS, DURATION_SEC = sys.argv[1:9]
REQ_RATE = float(REQ_RATE)
CONCURRENCY = int(CONCURRENCY)
MAX_TOKENS = int(MAX_TOKENS)
DURATION_SEC = int(DURATION_SEC)

API_URL = OLLAMA_URL.rstrip("/") + "/api/chat"  # native API (gives eval_count/durations)
HEADERS = {"Content-Type": "application/json"}

prompts = [json.loads(line)["messages"] for line in Path(PROMPT_FILE).read_text().splitlines() if line.strip()]
total_prompts = len(prompts)

# Poisson/Exponential inter-arrival generator
def next_interval(lmbda):
    # exponential with mean 1/lambda
    return random.expovariate(lmbda) if lmbda > 0 else 0.0

sem = asyncio.Semaphore(CONCURRENCY)

results = []
start_wall = time.perf_counter()
end_wall = start_wall + DURATION_SEC if DURATION_SEC > 0 else None
req_counter = 0

async def one_request(session, idx):
    payload = {
        "model": MODEL_NAME,
        "messages": prompts[idx % total_prompts],
        "stream": False,
        "options": {
            "num_predict": MAX_TOKENS,
            "temperature": 0,
        },
    }
    t0 = time.perf_counter()
    status = "ok"
    err = None
    eval_count = 0
    prompt_eval_count = 0
    eval_duration = 0
    prompt_eval_duration = 0
    total_duration = 0
    output_len = 0
    try:
        async with session.post(API_URL, headers=HEADERS, json=payload, timeout=300) as resp:
            txt = await resp.text()
            if resp.status != 200:
                status = f"http_{resp.status}"
                err = txt[:200]
            else:
                data = json.loads(txt)
                # Ollama native returns these when stream=false
                eval_count = int(data.get("eval_count", 0))
                prompt_eval_count = int(data.get("prompt_eval_count", 0))
                eval_duration = int(data.get("eval_duration", 0))              # ns
                prompt_eval_duration = int(data.get("prompt_eval_duration", 0))# ns
                total_duration = int(data.get("total_duration", 0))            # ns
                # completion content length (rough size proxy)
                msg = data.get("message", {}) or {}
                content = msg.get("content", "") or ""
                output_len = len(content)
    except Exception as e:
        status = "exc"
        err = str(e)[:200]
    t1 = time.perf_counter()
    results.append({
        "idx": idx,
        "status": status,
        "err": err,
        "latency_s": t1 - t0,
        "eval_count": eval_count,
        "prompt_eval_count": prompt_eval_count,
        "eval_duration_s": eval_duration/1e9 if eval_duration else 0.0,
        "prompt_eval_duration_s": prompt_eval_duration/1e9 if prompt_eval_duration else 0.0,
        "total_duration_s": total_duration/1e9 if total_duration else (t1 - t0),
        "output_len_chars": output_len,
    })

async def producer():
    global req_counter
    connector = aiohttp.TCPConnector(limit=CONCURRENCY)
    async with aiohttp.ClientSession(connector=connector) as session:
        next_idx = 0
        while True:
            now = time.perf_counter()
            if end_wall and now >= end_wall:
                break
            await sem.acquire()
            asyncio.create_task(launch(session, next_idx))
            next_idx += 1
            req_counter += 1
            # sleep for exponential inter-arrival
            await asyncio.sleep(next_interval(REQ_RATE))
        # wait for all in-flight to finish
        while sem._value < CONCURRENCY:
            await asyncio.sleep(0.05)

async def launch(session, idx):
    try:
        await one_request(session, idx)
    finally:
        sem.release()

asyncio.run(producer())

# Summaries
wall = time.perf_counter() - start_wall
ok = [r for r in results if r["status"] == "ok"]
fail = [r for r in results if r["status"] != "ok"]
lat = [r["latency_s"] for r in ok]
gen_tokens = sum(r["eval_count"] for r in ok)
gen_time = sum(r["eval_duration_s"] for r in ok)
prompt_tokens = sum(r["prompt_eval_count"] for r in ok)
prompt_time = sum(r["prompt_eval_duration_s"] for r in ok)

agg_tps = (gen_tokens / gen_time) if gen_time > 0 else 0.0
endpoints = {
    "api_url": API_URL,
    "model": MODEL_NAME,
    "req_rate": REQ_RATE,
    "concurrency": CONCURRENCY,
    "max_tokens": MAX_TOKENS,
}
p50 = np.percentile(lat, 50) if lat else 0
p90 = np.percentile(lat, 90) if lat else 0
p95 = np.percentile(lat, 95) if lat else 0

summary = {
    "endpoints": endpoints,
    "wall_seconds": wall,
    "requests_sent": len(results),
    "successful": len(ok),
    "failed": len(fail),
    "latency_p50_s": p50,
    "latency_p90_s": p90,
    "latency_p95_s": p95,
    "prompt_tokens": prompt_tokens,
    "prompt_eval_time_s": prompt_time,
    "generated_tokens": gen_tokens,
    "gen_eval_time_s": gen_time,
    "aggregate_gen_tokens_per_sec": agg_tps,
}

Path(RESULT_FILE).write_text(json.dumps({"summary": summary, "requests": results}, indent=2))
print(json.dumps(summary, indent=2))
PY
