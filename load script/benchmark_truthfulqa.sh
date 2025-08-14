#!/bin/bash
# TruthfulQA Benchmarking Script for vLLM and Ollama

# ———————————————
# 1. Configuration Variables (modify these to adjust settings)
PROMPT_FILE="truthfulqa_prompts.jsonl"    # JSONL file to store TruthfulQA prompts
REQ_RATE=8                               # Target request rate (requests per second)
CONCURRENCY=16                           # Maximum concurrent requests
MAX_TOKENS=128                           # Max tokens to generate per prompt
MODEL_NAME="llama3.2:3b"                 # Model name to request (as recognized by Ollama)
OLLAMA_URL="http://localhost:11434"      # Base URL of the Ollama server (OpenAI-compatible API)
ENDPOINT="/v1/chat/completions"          # API endpoint for chat completions
RESULT_FILE="vllm_bench_truthfulqa.json" # Output filename for JSON results
LOG_FILE="vllm_bench_output.log"         # Log file for detailed benchmark output
# ———————————————

set -e  # Exit on any error

echo "=== Setting up dependencies ==="
# Ensure required system packages are installed
sudo apt-get update -y
sudo apt-get install -y git python3-pip python3-dev build-essential

# Upgrade pip to latest version
pip3 install --upgrade pip

# Install Hugging Face Datasets if not already installed
pip3 show datasets >/dev/null 2>&1 || pip3 install datasets

# Clone vLLM from source and install it (if not already present)
if [ -d "vllm" ]; then
    echo "vLLM source directory already exists, skipping clone."
else
    echo "Cloning vLLM repository..."
    git clone https://github.com/vllm-project/vllm.git
fi

# Install vLLM in editable mode (this will compile any needed parts or download pre-built wheels)
# If vLLM is already installed, this will ensure it's up to date.
pip3 show vllm >/dev/null 2>&1 && echo "vLLM already installed, upgrading..."
pip3 install -e ./vllm

echo
echo "=== Downloading TruthfulQA dataset and preparing prompts ==="
if [ -f "$PROMPT_FILE" ]; then
    echo "Prompt file '$PROMPT_FILE' already exists. Skipping dataset download."
else
    # Use Python to download TruthfulQA (generation split) and create JSONL of prompts
    python3 <<PYCODE
import json
from datasets import load_dataset

# Load TruthfulQA generation dataset (will download if not cached)
ds = load_dataset("truthful_qa", "generation")
questions = ds["validation"]["question"]  # list of question strings (817 prompts)

# Write each question as a JSON line for chat API format
with open("${PROMPT_FILE}", "w") as f:
    for q in questions:
        prompt_obj = {"messages": [{"role": "user", "content": q}]}
        f.write(json.dumps(prompt_obj) + "\n")
PYCODE
    PROMPT_COUNT=$(wc -l < "$PROMPT_FILE")
    echo "Saved $PROMPT_COUNT prompts to $PROMPT_FILE"
fi

# Safety check: verify Ollama server is reachable
OLLAMA_HOST=$(echo "$OLLAMA_URL" | sed -E 's|https?://([^:/]+).*|\1|')
OLLAMA_PORT=$(echo "$OLLAMA_URL" | sed -E 's|.*:([0-9]+).*|\1|')
echo
echo "=== Checking Ollama server at $OLLAMA_URL ==="
if bash -c "echo > /dev/tcp/${OLLAMA_HOST}/${OLLAMA_PORT}" 2>/dev/null; then
    echo "Ollama server is up, proceeding with benchmark..."
else
    echo "WARNING: Cannot connect to Ollama at $OLLAMA_URL. Please ensure the server is running."
fi

echo
echo "=== Running vLLM benchmark_serving.py ==="
# Remove old result file to avoid confusion (if exists)
rm -f "$RESULT_FILE"
# Run the benchmark and tee output to a log file for parsing
python3 vllm/benchmarks/benchmark_serving.py \
    --backend openai-chat \
    --base-url "$OLLAMA_URL" \
    --endpoint "$ENDPOINT" \
    --model "$MODEL_NAME" \
    --dataset-name sharegpt \
    --dataset-path "$PROMPT_FILE" \
    --num-prompts $(wc -l < "$PROMPT_FILE") \
    --max-concurrency $CONCURRENCY \
    --request-rate $REQ_RATE \
    --sharegpt-output-len $MAX_TOKENS \
    --disable-tqdm \
    --save-result \
    --result-dir . \
    --result-filename "$RESULT_FILE" | tee "$LOG_FILE"

echo
echo "=== Benchmark completed ==="
# Parse summary metrics from the log output
TOTAL_PROMPTS=\$(grep -m1 "Successful requests" "$LOG_FILE" | cut -d':' -f2 | tr -d ' ')
TOKENS_PER_SEC=\$(grep -m1 "Output token throughput" "$LOG_FILE" | cut -d':' -f2 | tr -d ' ')
echo "Completed \$TOTAL_PROMPTS prompts with throughput of \$TOKENS_PER_SEC tokens/sec."

echo "Detailed per-request results saved to $RESULT_FILE"
