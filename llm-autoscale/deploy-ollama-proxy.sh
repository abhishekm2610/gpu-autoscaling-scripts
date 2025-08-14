#!/bin/bash
# deploy-ollama-proxy.sh
# Script to deploy the Ollama proxy system

set -e

echo "==> Deploying Ollama Proxy System"

# Create namespace if it doesn't exist
echo "Creating namespace 'llm'..."
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -

# Apply ConfigMap first
echo "Applying proxy ConfigMap..."
kubectl apply -f ollama-proxy-configmap.yaml

# Apply Deployment
echo "Applying proxy Deployment..."
kubectl apply -f ollama-proxy-deployment.yaml

# Apply Service
echo "Applying proxy Service..."
kubectl apply -f ollama-proxy-service.yaml

# Apply ServiceMonitor for Prometheus
echo "Applying proxy ServiceMonitor..."
kubectl apply -f ollama-proxy-servicemonitor.yaml

# Apply HPA (if metrics server is available)
echo "Applying HPA..."
kubectl apply -f ollama-proxy-hpa.yaml

echo ""
echo "==> Deployment completed!"
echo ""
echo "To check the status:"
echo "  kubectl get pods -n llm"
echo "  kubectl get svc -n llm"
echo "  kubectl get hpa -n llm"
echo ""
echo "To view logs:"
echo "  kubectl logs -n llm deployment/ollama-proxy -f"
echo ""
echo "To test the proxy:"
echo "  kubectl port-forward -n llm svc/ollama-proxy 9090:9090"
echo "  curl http://localhost:9090/health"
echo "  curl http://localhost:9090/metrics"
echo ""
echo "Proxy endpoint: http://ollama-proxy.llm.svc.cluster.local:9090/proxy"
