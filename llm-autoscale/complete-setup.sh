#!/bin/bash
# complete-setup.sh
# Complete setup for Ollama proxy with custom metrics

set -e

echo "==> Complete Ollama Proxy Setup with Custom Metrics"

# Step 1: Deploy the proxy system
echo "1. Deploying Ollama proxy..."
./deploy-ollama-proxy.sh

# Step 2: Apply monitoring configuration
echo ""
echo "2. Setting up monitoring..."
kubectl apply -f ollama-proxy-servicemonitor.yaml
kubectl apply -f ollama-proxy-podmonitor.yaml

# Step 3: Wait for proxy to be ready
echo ""
echo "3. Waiting for proxy to be ready..."
kubectl wait --for=condition=ready pod -l app=ollama-proxy -n llm --timeout=120s

# Step 4: Generate some test traffic to populate metrics
echo ""
echo "4. Generating test traffic to populate metrics..."
kubectl port-forward -n llm svc/ollama-proxy 9090:9090 &
PF_PID=$!
sleep 5

echo "Making test requests..."
for i in {1..5}; do
    curl -s -X POST http://localhost:9090/proxy/api/generate \
        -H "Content-Type: application/json" \
        -d '{"model":"llama3.2:3b","prompt":"Test request '$i'","stream":false}' > /dev/null &
done

# Wait for requests to complete
sleep 30
kill $PF_PID 2>/dev/null

# Step 5: Check metrics are available
echo ""
echo "5. Checking proxy metrics..."
kubectl port-forward -n llm svc/ollama-proxy 9090:9090 &
PF_PID=$!
sleep 3

echo "Current metrics:"
curl -s http://localhost:9090/metrics | grep ollama_proxy

kill $PF_PID 2>/dev/null

# Step 6: Setup custom metrics for HPA
echo ""
echo "6. Setting up custom metrics for HPA..."
./setup-custom-metrics.sh

# Step 7: Test custom metrics API
echo ""
echo "7. Testing custom metrics API..."
sleep 10

echo "Available custom metrics:"
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1' | jq '.resources[].name' | grep ollama || echo "No ollama metrics found yet"

echo ""
echo "==> Complete setup finished!"
echo ""
echo "To test the system:"
echo "1. Generate load:"
echo "   kubectl port-forward -n llm svc/ollama-proxy 9090:9090"
echo "   # Then use your load testing scripts"
echo ""
echo "2. Monitor scaling:"
echo "   watch kubectl get pods -n llm"
echo "   kubectl get hpa -n llm -w"
echo ""
echo "3. Check metrics:"
echo "   kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/services/ollama-proxy/ollama_proxy_utilization'"
