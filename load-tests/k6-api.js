import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const apiLatency = new Trend('api_latency', true);

// Configuration
const BASE_URL = __ENV.BASE_URL || 'http://localhost:4801';
const API_TOKEN = __ENV.API_TOKEN || '';

const headers = {
  'Content-Type': 'application/json',
  ...(API_TOKEN ? { 'Authorization': `Bearer ${API_TOKEN}` } : {}),
};

// Test scenarios
export const options = {
  scenarios: {
    // Smoke test: verify endpoints work
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10s',
      exec: 'smokeTest',
      tags: { scenario: 'smoke' },
    },
    // Load test: sustained traffic
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '1m', target: 10 },
        { duration: '30s', target: 20 },
        { duration: '1m', target: 20 },
        { duration: '30s', target: 0 },
      ],
      exec: 'loadTest',
      startTime: '15s',
      tags: { scenario: 'load' },
    },
    // Stress test: find breaking point
    stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 30 },
        { duration: '1m', target: 50 },
        { duration: '30s', target: 0 },
      ],
      exec: 'loadTest',
      startTime: '4m',
      tags: { scenario: 'stress' },
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<2000', 'p(99)<5000'],
    errors: ['rate<0.05'],
    api_latency: ['p(95)<1500'],
  },
};

// Health check endpoints (no auth needed)
export function smokeTest() {
  group('Health Checks', () => {
    const health = http.get(`${BASE_URL}/api/health/live`);
    check(health, { 'health live 200': (r) => r.status === 200 });

    const ready = http.get(`${BASE_URL}/api/health/ready`);
    check(ready, { 'health ready 200': (r) => r.status === 200 });
  });

  sleep(1);
}

// Main API endpoints
export function loadTest() {
  group('Read APIs', () => {
    // Budget status
    const budget = http.get(`${BASE_URL}/api/v1/budget/status`, { headers });
    const budgetOk = check(budget, { 'budget 200': (r) => r.status === 200 });
    errorRate.add(!budgetOk);
    apiLatency.add(budget.timings.duration);

    // Runs list
    const runs = http.get(`${BASE_URL}/api/v1/runs?limit=10`, { headers });
    const runsOk = check(runs, { 'runs 200': (r) => r.status === 200 });
    errorRate.add(!runsOk);
    apiLatency.add(runs.timings.duration);

    // Audit events
    const audit = http.get(`${BASE_URL}/api/v1/audit?limit=10`, { headers });
    const auditOk = check(audit, { 'audit 200': (r) => r.status === 200 });
    errorRate.add(!auditOk);
    apiLatency.add(audit.timings.duration);

    // Kanban cards
    const cards = http.get(`${BASE_URL}/api/v1/kanban/cards`, { headers });
    const cardsOk = check(cards, { 'kanban 200': (r) => r.status === 200 });
    errorRate.add(!cardsOk);
    apiLatency.add(cards.timings.duration);

    // Traces
    const traces = http.get(`${BASE_URL}/api/v1/traces?limit=5`, { headers });
    const tracesOk = check(traces, { 'traces 200': (r) => r.status === 200 });
    errorRate.add(!tracesOk);
    apiLatency.add(traces.timings.duration);

    // Config
    const config = http.get(`${BASE_URL}/api/v1/config/claude-flow`, { headers });
    apiLatency.add(config.timings.duration);
  });

  group('Rate Limit Test', () => {
    // Rapid-fire to test rate limiter behavior
    for (let i = 0; i < 3; i++) {
      const resp = http.get(`${BASE_URL}/api/v1/budget/status`, { headers });
      if (resp.status === 429) {
        check(resp, { 'rate limit has retry-after': (r) => r.headers['Retry-After'] !== undefined });
      }
    }
  });

  sleep(0.5 + Math.random());
}
