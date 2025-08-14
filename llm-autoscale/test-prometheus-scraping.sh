#!/bin/bash
# test-prometheus-scraping.sh
# Test if Prometheus is scraping the proxy metrics

echo "==> Testing Prometheus Scraping"

# Check if Prometheus is available
PROMETHEUS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$PROMETHEUS_POD" ]; then
    echo "Warning: Prometheus pod not found in monitoring namespace"
    echo "Checking other namespaces..."
    PROMETHEUS_POD=$(kubectl get pods -A -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    PROMETHEUS_NS=$(kubectl get pods -A -l app=prometheus -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
else
    PROMETHEUS_NS="monitoring"
fi

if [ -z "$PROMETHEUS_POD" ]; then
    echo "Error: No Prometheus pod found"
    exit 1
fi

echo "Found Prometheus pod: $PROMETHEUS_POD in namespace: $PROMETHEUS_NS"

# Port-forward to Prometheus
echo "Setting up port-forward to Prometheus..."
kubectl port-forward -n $PROMETHEUS_NS pod/$PROMETHEUS_POD 9090:9090 &
PF_PID=$!
sleep 5

# Query for ollama proxy metrics
echo ""
echo "==> Checking if Ollama proxy metrics are available in Prometheus:"

echo "1. Checking targets..."
curl -s "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job | contains("ollama")) | {job: .labels.job, health: .health, lastScrape: .lastScrape}'

echo ""
echo "2. Querying ollama_proxy_utilization_percent..."
curl -s "http://localhost:9090/api/v1/query?query=ollama_proxy_utilization_percent" | jq '.data.result'

echo ""
echo "3. Querying ollama_proxy_requests_total..."
curl -s "http://localhost:9090/api/v1/query?query=ollama_proxy_requests_total" | jq '.data.result'

# Clean up
kill $PF_PID 2>/dev/null

echo ""
echo "==> Test completed!"
