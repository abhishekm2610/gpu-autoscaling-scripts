#!/bin/bash
# generate-load.sh
# Generate some load to populate metrics

echo "==> Generating load to populate metrics"

# Port-forward in background
kubectl port-forward -n llm svc/ollama-proxy 9092:9090 &
PF_PID=$!
sleep 5

echo "Testing proxy health..."
if ! curl -s http://localhost:9092/health > /dev/null; then
    echo "ERROR: Proxy not responding"
    kill $PF_PID 2>/dev/null
    exit 1
fi

echo "Proxy is healthy. Generating test requests..."

# Generate some concurrent requests to increase active request count
for i in {1..3}; do
    echo "Starting batch $i..."
    for j in {1..2}; do
        curl -s -X POST http://localhost:9092/proxy/api/generate \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"llama3.2:3b\",\"prompt\":\"Test request batch $i request $j\",\"stream\":false}" > /dev/null &
    done
    sleep 2
done

echo "Waiting for requests to complete..."
sleep 10

echo "Current metrics:"
curl -s http://localhost:9092/metrics | grep ollama_proxy_active_requests || echo "No active requests metric found"

# Clean up
kill $PF_PID 2>/dev/null

echo "Load generation completed!"
