# Load Tests

k6 load test scripts for the orchestrator API.

## Prerequisites

Install k6: `brew install k6`

## Usage

```bash
# Smoke test (verify endpoints work)
k6 run --env BASE_URL=http://localhost:4801 load-tests/k6-api.js

# Quick load test only (skip stress)
k6 run --env BASE_URL=http://localhost:4801 --tag scenario=load load-tests/k6-api.js

# With API auth token
k6 run --env BASE_URL=http://localhost:4801 --env API_TOKEN=your-token load-tests/k6-api.js
```

## Thresholds

- p95 response time < 2s
- p99 response time < 5s
- Error rate < 5%
- API latency p95 < 1.5s

## Scenarios

| Scenario | VUs | Duration | Purpose |
|----------|-----|----------|---------|
| smoke | 1 | 10s | Verify endpoints respond |
| load | 10→20 | 3m | Sustained traffic |
| stress | 30→50 | 2m | Find breaking point |
