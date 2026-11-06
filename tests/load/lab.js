import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

function integer(name, fallback, min, max) {
    const raw = __ENV[name] || String(fallback);
    if (!/^\d+$/.test(raw) || Number(raw) < min || Number(raw) > max) {
        throw new Error(`${name} must be an integer from ${min} to ${max}`);
    }
    return Number(raw);
}

const api = (__ENV.API_URL || '').replace(/\/$/, '');
if (!/^https:\/\/[a-zA-Z0-9.-]+(?::\d+)?\/lab$/.test(api)) {
    throw new Error('API_URL must be an HTTPS /lab URL without credentials, query or fragment');
}
const regions = [__ENV.PRIMARY_REGION, __ENV.SECONDARY_REGION];
if (regions.some(region => !region || !/^[a-z0-9]+$/.test(region)) || regions[0] === regions[1]) {
    throw new Error('PRIMARY_REGION and SECONDARY_REGION must identify distinct Azure regions');
}
const vus = integer('LOAD_VUS', 2, 1, 50);
const duration = integer('LOAD_SECONDS', 60, 1, 600);
const p95 = integer('LOAD_P95_MS', 1500, 1, 60000);
const p99 = integer('LOAD_P99_MS', 3000, p95, 60000);
const invalidResponse = new Rate('lab_invalid_response');
const regionRates = regions.map(region => new Rate(`lab_region_${region}`));

export const options = {
    scenarios: {
        bounded: {
            executor: 'constant-vus',
            vus,
            duration: `${duration}s`,
            gracefulStop: '15s',
        },
    },
    maxRedirects: 0,
    insecureSkipTLSVerify: false,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    thresholds: {
        http_req_duration: [`p(95)<${p95}`, `p(99)<${p99}`],
        http_req_failed: ['rate<0.01'],
        lab_invalid_response: ['rate<0.01'],
        checks: ['rate>0.99'],
    },
};

export function setup() {
    if (__ENV.CONFIRM_LOAD !== 'yes') {
        throw new Error('Set CONFIRM_LOAD=yes only after authorizing traffic to this lab');
    }
}

export default function () {
    const response = http.get(`${api}/whoami`, {
        timeout: '10s',
        tags: { name: 'GET /lab/whoami' },
        headers: { 'Cache-Control': 'no-cache' },
    });
    let body;
    if (response.status === 200) {
        try {
            body = response.json();
        } catch (error) {
            console.error(`Invalid JSON response: HTTP ${response.status}`);
        }
    }
    const gateway = String(response.headers['X-Lab-Gateway-Region'] || '')
        .replace(/\s+/g, '').toLowerCase();
    const valid = check(response, {
        'HTTP 200': result => result.status === 200,
        'backend identity': () => !!body && regions.includes(body.region)
            && typeof body.cluster === 'string' && body.cluster.length > 0
            && typeof body.pod === 'string' && body.pod.length > 0,
        'gateway/backend locality': () => !!body && gateway === body.region,
    });
    invalidResponse.add(!valid);
    regionRates.forEach((metric, index) => metric.add(!!body && body.region === regions[index]));
    sleep(1);
}
