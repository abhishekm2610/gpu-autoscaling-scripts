# Ollama Proxy System

This system provides a centralized proxy for Ollama requests that enables proper autoscaling based on actual load metrics.

## Problem Solved

When Ollama pods are autoscaled, new pods report 0% utilization because they don't receive traffic initially and don't have visibility into cluster-wide load. This proxy solves that by:

1. **Centralized Load Balancing**: All requests go through a single proxy that distributes them to available Ollama pods
2. **Cluster-wide Metrics**: The proxy aggregates metrics from all requests, providing accurate utilization data
3. **Smart Autoscaling**: HPA uses proxy metrics to make better scaling decisions

## Architecture

```
Client Requests → Ollama Proxy → Load Balance → Ollama Pods
                      ↓
                 Prometheus Metrics → HPA → Scale Ollama Pods
```

## Components

### 1. Ollama Proxy (`ollama-proxy-deployment.yaml`)
- Python-based async proxy server
- Routes requests to Ollama service endpoints
- Tracks request metrics and utilization
- Exposes Prometheus metrics

### 2. Services
- `ollama-proxy-service.yaml`: Exposes the proxy on port 9090
- `ollama-service.yaml`: Existing Ollama service (already present)

### 3. Monitoring
- `ollama-proxy-servicemonitor.yaml`: Prometheus scraping configuration
- Metrics exposed at `/metrics` endpoint

### 4. Autoscaling
- `ollama-proxy-hpa.yaml`: HPA based on proxy utilization metrics
- Scales Ollama deployment based on `ollama_proxy_utilization_percent`

## Deployment

1. **Deploy the proxy system:**
   ```bash
   ./deploy-ollama-proxy.sh
   ```

2. **Verify deployment:**
   ```bash
   kubectl get pods -n llm
   kubectl get svc -n llm
   kubectl get hpa -n llm
   ```

3. **Check proxy health:**
   ```bash
   kubectl port-forward -n llm svc/ollama-proxy 9090:9090
   curl http://localhost:9090/health
   curl http://localhost:9090/metrics
   ```

## Usage

### From within cluster:
```bash
# Send requests to the proxy instead of directly to Ollama
curl -X POST http://ollama-proxy.llm.svc.cluster.local:9090/proxy/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:3b","prompt":"Hello world","stream":false}'
```

### Load Testing:
```bash
# Update your load testing scripts to use the proxy
URL="http://ollama-proxy.llm.svc.cluster.local:9090/proxy"
```

## Metrics

The proxy exposes several metrics for monitoring and autoscaling:

- `ollama_proxy_requests_total`: Total requests processed
- `ollama_proxy_active_requests`: Currently active requests
- `ollama_proxy_requests_per_minute`: Request rate
- `ollama_proxy_avg_response_time`: Average response time
- `ollama_proxy_utilization_percent`: **Key metric for HPA** (0-100%)
- `ollama_proxy_healthy_endpoints`: Number of healthy Ollama endpoints

## Autoscaling Configuration

The HPA is configured to:
- **Target**: 70% utilization on the proxy
- **Min replicas**: 1
- **Max replicas**: 10
- **Scale up**: Aggressive (100% increase when needed)
- **Scale down**: Conservative (10% decrease with 5min stabilization)

## Troubleshooting

### Check proxy logs:
```bash
kubectl logs -n llm deployment/ollama-proxy -f
```

### Check HPA status:
```bash
kubectl describe hpa -n llm ollama-hpa
```

### Test proxy directly:
```bash
kubectl port-forward -n llm svc/ollama-proxy 9090:9090
curl http://localhost:9090/metrics
```

### Monitor scaling:
```bash
watch kubectl get pods -n llm
```

## Configuration

### Adjust scaling sensitivity:
Edit `ollama-proxy-hpa.yaml` and modify:
- `averageValue`: Target utilization percentage
- `minReplicas`/`maxReplicas`: Scaling bounds
- `behavior`: Scaling speed and stabilization

### Modify proxy behavior:
Edit the Python code in `ollama-proxy-configmap.yaml`:
- Load balancing algorithm
- Health check intervals
- Utilization calculation
- Request routing logic

## Benefits

1. **Accurate Metrics**: Cluster-wide view of load instead of per-pod metrics
2. **Better Scaling**: HPA makes decisions based on actual demand
3. **Load Distribution**: Requests are evenly distributed across pods
4. **Health Monitoring**: Automatic detection of unhealthy endpoints
5. **Observability**: Rich metrics for monitoring and alerting
