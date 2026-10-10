# Baseline BEFORE tuning - QA, 2026-10-10 21:59:56Z -> 22:07:20Z (about 7.4 min)

Account: dedicated QA requester. Read-only GETs. Ramp 5 -> 20 -> 50 virtual users. By-city CITY_ID 114212277121206 (3 lands).
Data set on QA is tiny (2 lands within 5 km of Cairo centre), so query cost is much lower than production will be.
Deployed images at the time were the ones before the perf-* branches (no latency buckets, no Tomcat metrics).

## Client side (k6) - `baseline-before-k6.json`
| Endpoint | p50 ms | p95 ms | p99 ms | max ms |
|---|---|---|---|---|
| nearby_available (Find Parking search) | 96 | 221 | 399 | 1244 |
| by_city (Book Advance listing) | 101 | 218 | 452 | 1661 |
| land_spots | 103 | 218 | 474 | 1275 |
| spot_details | 95 | 192 | 357 | 1175 |
| profile | 89 | 167 | 263 | 954 |
| all requests | 97 | 203 | 399 | 1661 |

21,251 requests (50.4 req/s average, 4,250 iterations), **0 failed** (error rate 0.00%), all checks passed, all thresholds passed, abort thresholds never tripped.

## Server side - `baseline-before-server-metrics.json`
| Service | Hikari active max / pool | pending | CPU avg / max (fraction of its 1-CPU limit) | JVM threads max | req/s (non-stream) |
|---|---|---|---|---|---|
| gateway-service | n/a (no DB) | - | **0.64 / 0.93** | 40 | 49 |
| user-service | 6 / 10 | 0 | 0.20 / 0.42 | 55 | **147** |
| landlord-service | 6 / 10 | 0 | 0.18 / 0.32 | 66 | 39 |
| requester-service | 0 / 10 | 0 | 0.04 / 0.15 | 49 | 10 |
| booking, payment, admin, corporate, notification | 0 / 10 | 0 | <= 0.03 | 43-59 | ~0.3 |

RDS `landers-db`: DatabaseConnections 81 (flat, = 9 services x 10 idle + 1), CPU 26% average, CPU credit balance 576 (no drain), no Hikari timeouts, no 5xx.
Tomcat busy threads: **not available** (metric only exists after the Tomcat-metrics commit is deployed).

## Notable
1. The gateway is the first thing to saturate: 64% average / 93% peak of one CPU at only ~50 req/s.
2. user-service receives ~3x the gateway's request rate: the gateway's `UserStatusFilter` calls `GET /api/v1/users/auth/status/{userId}` on every authenticated request, uncached.
3. HPA scaled gateway-service 1 -> 2 and user-service 1 -> 3 right after the ramp. The user-service pods created by the scale-out **crash-loop**: the live `user-service-config` ConfigMap on QA is still the old MySQL one (jdbc:mysql://mysql-db), so new pods cannot reach a database. The one old pod keeps serving. See PERFORMANCE_AUDIT.md section 7.
