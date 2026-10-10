// k6 read-only load test for the busiest requester endpoints. QA / staging ONLY - never production.
//
//   k6 run -e BASE_URL=https://qa-api.landersfolk.com -e USERNAME=<requester> -e PASSWORD=<pw> \
//          -e LAT=30.0444 -e LNG=31.2357 -e CITY_ID=<id> load-tests/qa-baseline.k6.js
//
// GETs only (no bookings/payments are created). Credentials come from the environment, never the file.
// Record the baseline BEFORE any tuning change, then re-run after each one with the same parameters:
//   k6 run --summary-export=baseline.json ...
// Compare http_req_duration p(95)/p(99), http_req_failed and the Grafana panels listed in PERFORMANCE_AUDIT.md.
import http from 'k6/http';
import {check, sleep} from 'k6';

const BASE = __ENV.BASE_URL || 'https://qa-api.landersfolk.com';
const LAT = __ENV.LAT || '30.0444';
const LNG = __ENV.LNG || '31.2357';
const CITY_ID = __ENV.CITY_ID || '';

export const options = {
  scenarios: {
    // Closed-model ramp: 5 -> 25 -> 50 virtual users, hold, ramp down.
    browse: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        {duration: '1m', target: 5},
        {duration: '2m', target: 25},
        {duration: '3m', target: 50},
        {duration: '1m', target: 0},
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:nearby_available}': ['p(95)<800'],
    'http_req_duration{name:by_city}': ['p(95)<800'],
    'http_req_duration{name:profile}': ['p(95)<500'],
  },
};

export function setup() {
  const res = http.post(
    `${BASE}/api/v1/auth/login`,
    JSON.stringify({username: __ENV.USERNAME, password: __ENV.PASSWORD}),
    {headers: {'Content-Type': 'application/json', app_id: 'landers-requester'}},
  );
  check(res, {'login 200': r => r.status === 200});
  const body = res.json();
  const token = (body && (body.access_token || (body.data && body.data.access_token))) || '';
  if (!token) { throw new Error('login did not return an access token - check USERNAME/PASSWORD/app_id'); }
  return {token};
}

export default function (data) {
  const params = {headers: {Authorization: `Bearer ${data.token}`, app_id: 'landers-requester'}};

  // Find Parking: nearby available lands (geo query - the hottest read path).
  let r = http.get(
    `${BASE}/api/v1/landlords/location/lands/nearby/available?latitude=${LAT}&longitude=${LNG}&radiusMeters=5000&limit=20`,
    {...params, tags: {name: 'nearby_available'}},
  );
  check(r, {'nearby 200': x => x.status === 200});

  // Book Advance: by-city search.
  if (CITY_ID) {
    r = http.get(`${BASE}/api/v1/landlords/location/lands/by-city?cityId=${CITY_ID}&limit=20`,
      {...params, tags: {name: 'by_city'}});
    check(r, {'by-city 200': x => x.status === 200});
  }

  // Typical authenticated lookup used by every app start.
  r = http.get(`${BASE}/api/v1/requester/profile`, {...params, tags: {name: 'profile'}});
  check(r, {'profile 2xx': x => x.status >= 200 && x.status < 300});

  sleep(1 + Math.random() * 2); // think time
}
