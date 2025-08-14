# Troubleshooting Custom Metrics for HPA

## Overview
This guide helps you troubleshoot the integration between Ollama proxy metrics, Prometheus, Prometheus Adapter, and HPA.

## Step-by-Step Debugging

### 1. Check Proxy Metrics
```bash
# Port-forward to proxy
kubectl port-forward -n llm svc/ollama-proxy 9090:9090

# Check metrics endpoint
curl http://localhost:9090/metrics | grep ollama_proxy
```

**Expected output:**
- `ollama_proxy_utilization_percent` should show a value 0-100
- `ollama_proxy_requests_total` should increment with requests

### 2. Check Prometheus Scraping

```bash
# Find Prometheus pod
kubectl get pods -A | grep prometheus

# Port-forward to Prometheus
kubectl port-forward -n monitoring pod/prometheus-xxx 9090:9090

# Check targets
curl "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job | contains("ollama"))'

# Query metrics
curl "http://localhost:9090/api/v1/query?query=ollama_proxy_utilization_percent" | jq
```

**Issues and Solutions:**

- **No targets found:** Check ServiceMonitor/PodMonitor labels match the service/pod labels
- **Target DOWN:** Check network connectivity, service ports
- **No metrics:** Check proxy /metrics endpoint is accessible

### 3. Check ServiceMonitor/PodMonitor

```bash
# Check ServiceMonitor
kubectl get servicemonitor -n llm ollama-proxy-servicemonitor -o yaml

# Check if Prometheus operator is configured to watch this namespace
kubectl get prometheus -A -o yaml | grep -A5 -B5 serviceMonitorNamespaceSelector
```

**Common issues:**
- ServiceMonitor in wrong namespace
- Label selectors don't match
- Prometheus operator not watching the namespace

### 4. Check Prometheus Adapter Configuration

```bash
# Check adapter config
kubectl get configmap adapter-config -n monitoring -o yaml

# Check adapter logs
kubectl logs -n monitoring deployment/prometheus-adapter

# Test custom metrics API
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1'
```

**Common issues:**
- Adapter config not applied
- Metrics query syntax errors
- Resource mapping issues

### 5. Check HPA Configuration

```bash
# Check HPA status
kubectl get hpa -n llm ollama-hpa -o yaml
kubectl describe hpa -n llm ollama-hpa

# Check available metrics
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/services/ollama-proxy/ollama_proxy_utilization'
```

**Common issues:**
- Metric name mismatch
- Wrong resource reference
- Missing RBAC permissions

## Quick Fixes

### Fix 1: ServiceMonitor Not Working
```bash
# Apply PodMonitor instead
kubectl apply -f ollama-proxy-podmonitor.yaml

# Or add labels to ServiceMonitor
kubectl label servicemonitor ollama-proxy-servicemonitor -n llm release=prometheus
```

### Fix 2: Prometheus Not Scraping
```bash
# Check service labels
kubectl get svc ollama-proxy -n llm --show-labels

# Add prometheus annotations to service
kubectl annotate svc ollama-proxy -n llm prometheus.io/scrape=true
kubectl annotate svc ollama-proxy -n llm prometheus.io/port=9090
kubectl annotate svc ollama-proxy -n llm prometheus.io/path=/metrics
```

### Fix 3: Custom Metrics Not Available
```bash
# Restart prometheus adapter
kubectl rollout restart deployment/prometheus-adapter -n monitoring

# Wait and check
kubectl rollout status deployment/prometheus-adapter -n monitoring
sleep 30
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1' | jq '.resources[].name'
```

### Fix 4: HPA Not Scaling
```bash
# Check if metric value is available
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/services/ollama-proxy/ollama_proxy_utilization' | jq

# If no value, generate some load
kubectl port-forward -n llm svc/ollama-proxy 9090:9090 &
for i in {1..10}; do
  curl -X POST http://localhost:9090/proxy/api/generate \
    -H "Content-Type: application/json" \
    -d '{"model":"llama3.2:3b","prompt":"Load test","stream":false}' &
done
```

## Alternative HPA Configuration

If custom metrics don't work, try using resource-based scaling temporarily:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ollama-hpa-backup
  namespace: llm
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ollama
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

## Monitoring Commands

```bash
# Watch HPA in real-time
kubectl get hpa -n llm -w

# Watch pods scaling
watch kubectl get pods -n llm

# Monitor custom metrics
watch "kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/services/ollama-proxy/ollama_proxy_utilization' | jq '.value'"

# Check proxy logs
kubectl logs -n llm deployment/ollama-proxy -f
```
