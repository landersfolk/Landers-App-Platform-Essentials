// k6 READ-ONLY load test for the busiest requester endpoints. QA / staging ONLY - never production.
// Search, listing and detail GETs only: no bookings, payments, notifications or any other write.
//
//   k6 run -e BASE_URL=https://qa-api.landersfolk.com -e USERNAME=<test requester> -e PASSWORD=<pw> \
//          -e LAT=30.0444 -e LNG=31.2357 -e CITY_ID=<id> --summary-export=results/<label>-k6.json \
//          load-tests/qa-baseline.k6.js
//
// Credentials come from the environment, never the file. Use ONE dedicated QA requester account.
// Ramp: 5 -> 20 -> 50 virtual users (about 8 minutes). The run aborts by itself when the error rate
// or the latency spikes (see thresholds), and can be stopped at any time with Ctrl+C.
import http from 'k6/http';
import {check, sleep} from 'k6';

const BASE = __ENV.BASE_URL || 'https://qa-api.landersfolk.com';
const LAT = __ENV.LAT || '30.0444';
const LNG = __ENV.LNG || '31.2357';
const CITY_ID = __ENV.CITY_ID || '';
const APP_ID = __ENV.APP_ID || 'landers-requester';

// -e WARMUP=1 runs only a 2-minute, 20-VU warm-up (not for measurement): freshly started pods run
// cold JVMs (JIT compilation eats most of a 1-CPU limit) and the autoscaler adds more cold pods under load,
// which makes a first run after any deploy look ~10x slower. Warm up, then run the real ramp.
const STAGES = __ENV.WARMUP
  ? [{duration: '30s', target: 20}, {duration: '90s', target: 20}, {duration: '10s', target: 0}]
  : [
      {duration: '30s', target: 5},  {duration: '1m', target: 5},
      {duration: '30s', target: 20}, {duration: '2m', target: 20},
      {duration: '30s', target: 50}, {duration: '2m', target: 50},
      {duration: '30s', target: 0},
    ];

export const options = {
  scenarios: {
    browse: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: STAGES,
      gracefulRampDown: '20s',
      gracefulStop: '20s',
    },
  },
  thresholds: {
    // Pass/fail targets
    'http_req_duration{name:nearby_available}': ['p(95)<800'],
    'http_req_duration{name:by_city}': ['p(95)<800'],
    'http_req_duration{name:land_spots}': ['p(95)<800'],
    'http_req_duration{name:spot_details}': ['p(95)<500'],
    'http_req_duration{name:profile}': ['p(95)<500'],
    // Safety stops: abort the whole run (30s grace so a ramp blip does not trip it).
    http_req_failed: [{threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s'}],
    http_req_duration: [{threshold: 'p(95)<3000', abortOnFail: true, delayAbortEval: '30s'}],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  const res = http.post(
    `${BASE}/api/v1/auth/login`,
    JSON.stringify({username: __ENV.USERNAME, password: __ENV.PASSWORD}),
    {headers: {'Content-Type': 'application/json', app_id: APP_ID}},
  );
  check(res, {'login 200': r => r.status === 200});
  const body = res.json();
  const token = (body && (body.access_token || (body.data && body.data.access_token))) || '';
  if (!token) { throw new Error('login did not return an access token - check USERNAME/PASSWORD/app_id'); }
  return {token};
}

// Pull a list out of the usual API envelopes: [..] | {data:[..]} | {data:{data:[..]}} | {content:[..]}
function items(res) {
  try {
    const b = res.json();
    const cands = [b, b && b.data, b && b.data && b.data.data, b && b.content, b && b.data && b.data.content];
    for (const c of cands) { if (Array.isArray(c)) { return c; } }
  } catch (e) { /* not JSON */ }
  return [];
}

export default function (data) {
  const params = {headers: {Authorization: `Bearer ${data.token}`, app_id: APP_ID}};
  const get = (path, name) => http.get(`${BASE}${path}`, {...params, tags: {name}});

  // Find Parking: nearby available lands (geo query, the hottest read).
  let r = get(`/api/v1/landlords/location/lands/nearby/available?latitude=${LAT}&longitude=${LNG}&radiusMeters=5000&limit=20`, 'nearby_available');
  check(r, {'nearby 200': x => x.status === 200});
  const lands = items(r);

  // Land -> its spots -> one spot's details (what the app loads when a card is opened).
  if (lands.length > 0) {
    const land = lands[Math.floor(Math.random() * lands.length)];
    const landId = land.id || land.landId;
    if (landId) {
      r = get(`/api/v1/landlords/lands/${landId}/spots`, 'land_spots');
      check(r, {'spots 200': x => x.status === 200});
      const spots = items(r);
      if (spots.length > 0 && spots[0].id) {
        r = get(`/api/v1/landlords/spots/${spots[0].id}`, 'spot_details');
        check(r, {'spot 200': x => x.status === 200});
      }
    }
  }

  // Book Advance: by-city listing.
  if (CITY_ID) {
    r = get(`/api/v1/landlords/location/lands/by-city?cityId=${CITY_ID}&limit=20`, 'by_city');
    check(r, {'by-city 200': x => x.status === 200});
  }

  // Authenticated lookup done at every app start.
  r = get('/api/v1/requester/profile', 'profile');
  check(r, {'profile 2xx': x => x.status >= 200 && x.status < 300});

  sleep(1 + Math.random() * 2); // think time
}
