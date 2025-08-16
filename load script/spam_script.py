import requests
import time
import threading
import json
from datetime import datetime
from queue import Queue

PROMPT_FILE = "truthfulqa_prompts_repo.txt"
ENDPOINT = "http://localhost:18080/proxy/api/generate"  # Change if your server uses a different port
MODEL = "llama3.2:3b"
OUTFILE = "inference_results_128_default_hpa_v3.json"
MAX_THREADS = 128  # Tune for your hardware/server

# Lock for safe concurrent access to the output file
file_lock = threading.Lock()

def send_prompt(prompt):
    start_dt = datetime.utcnow()
    start_time = time.time()
    payload = {
        "model": MODEL,
        "prompt": prompt,
        "stream": False
    }
    try:
        resp = requests.post(ENDPOINT, json=payload, timeout=300)
        end_dt = datetime.utcnow()
        elapsed = time.time() - start_time
        if resp.status_code != 200:
            result = {
                "prompt": prompt,
                "start_time_utc": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
                "end_time_utc": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
                "time_seconds": "ERROR",
                "output_tokens": "ERROR",
                "response": resp.text
            }
        else:
            try:
                data = resp.json()
                tokens = data.get("eval_count", "")
                result = {
                    "prompt": prompt,
                    "start_time_utc": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
                    "end_time_utc": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
                    "time_seconds": round(elapsed, 3),
                    "output_tokens": tokens,
                    "response": data
                }
            except Exception:
                result = {
                    "prompt": prompt,
                    "start_time_utc": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
                    "end_time_utc": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
                    "time_seconds": "ERROR",
                    "output_tokens": "ERROR",
                    "response": resp.text
                }
    except requests.exceptions.Timeout:
        end_dt = datetime.utcnow()
        result = {
            "prompt": prompt,
            "start_time_utc": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time_utc": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "time_seconds": "TIMEOUT",
            "output_tokens": "TIMEOUT",
            "response": None
        }
    except Exception as e:
        end_dt = datetime.utcnow()
        result = {
            "prompt": prompt,
            "start_time_utc": start_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time_utc": end_dt.strftime("%Y-%m-%d %H:%M:%S"),
            "time_seconds": "ERROR",
            "output_tokens": "ERROR",
            "response": str(e)
        }
    # Dump result to file as soon as it's available, safely
    with file_lock:
        with open(OUTFILE, "a", encoding="utf-8") as out:
            out.write(json.dumps(result, ensure_ascii=False) + "\n")

def worker(prompt_q):
    while True:
        prompt = prompt_q.get()
        if prompt is None:
            prompt_q.task_done()
            break
        send_prompt(prompt)
        prompt_q.task_done()

def main():
    with open(PROMPT_FILE, "r", encoding="utf-8") as f:
        prompts = [line.strip() for line in f if line.strip()]

    prompt_q = Queue()
    threads = []

    # Clear file at start so it's fresh
    open(OUTFILE, "w", encoding="utf-8").close()

    # Start worker threads
    for _ in range(min(MAX_THREADS, len(prompts))):
        t = threading.Thread(target=worker, args=(prompt_q,))
        t.start()
        threads.append(t)

    # Enqueue prompts
    for prompt in prompts:
        prompt_q.put(prompt)

    # Signal threads to exit
    for _ in threads:
        prompt_q.put(None)

    # Wait for all work to finish
    prompt_q.join()

    print(f"Completed {len(prompts)} prompts. Results written to {OUTFILE}.")

if __name__ == "__main__":
    main()