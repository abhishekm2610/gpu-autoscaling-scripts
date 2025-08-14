#!/bin/bash
# setup-custom-metrics.sh
# Script to configure Prometheus Adapter for Ollama proxy metrics

set -e

echo "==> Setting up Custom Metrics for Ollama Proxy"

# Check if prometheus-adapter exists
if ! kubectl get deployment prometheus-adapter -n monitoring &>/dev/null; then
    echo "Error: Prometheus Adapter not found in monitoring namespace"
    echo "Please install Prometheus Operator first"
    exit 1
fi

# Apply the adapter configuration
echo "Applying Prometheus Adapter configuration..."
kubectl apply -f prometheus-adapter-config.yaml

# Restart prometheus-adapter to pick up new config
echo "Restarting Prometheus Adapter..."
kubectl rollout restart deployment/prometheus-adapter -n monitoring

# Wait for rollout to complete
echo "Waiting for Prometheus Adapter to restart..."
kubectl rollout status deployment/prometheus-adapter -n monitoring --timeout=120s

# Replace the old HPA with the new custom metrics HPA
echo "Applying new HPA with custom metrics..."
kubectl delete hpa ollama-hpa -n llm --ignore-not-found=true
kubectl apply -f ollama-hpa-custom-metrics.yaml

echo ""
echo "==> Setup completed!"
echo ""
echo "To verify custom metrics are available:"
echo "  kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1' | jq"
echo "  kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/services/ollama-proxy/ollama_proxy_utilization' | jq"
echo ""
echo "To check HPA status:"
echo "  kubectl get hpa -n llm"
echo "  kubectl describe hpa ollama-hpa -n llm"
echo ""
echo "To monitor scaling:"
echo "  watch kubectl get pods -n llm"
