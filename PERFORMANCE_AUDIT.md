# Backend scalability & performance audit

Scope: the 9 Spring Boot services behind the gateway, their config (Helm chart + ConfigMaps), and the QA cluster.
Rule followed: no business logic, API, schema or behaviour changes; no new dependencies/infrastructure.
Facts below were read from the code/config and, for the cluster, from read-only `kubectl`/`aws` commands on 2026-10-11.

## 1. System summary

| Item | Finding |
|---|---|
| Java / framework | Java 21, Spring Boot 3.5.10, Spring Cloud 2025.0.0 (all services) |
| Gateway | `gateway-service`: **reactive** (WebFlux + Spring Cloud Gateway 4.3.0). Blocking work (Keycloak admin, Feign) is already offloaded to `boundedElastic`. |
| Other 8 services | **blocking Spring MVC / Tomcat** (200 threads, accept-count 100, defaults), JPA/Hibernate, Hikari |
| Database | one AWS RDS PostgreSQL 18, `db.t3.medium` (2 vCPU/4 GiB, burstable), single-AZ, no replica, 20 GiB; shared by all 9 services |
| Pools | Hikari max 10 per service on QA, 20 on prod (ConfigMaps). Worst case with HPA max 3: 270 (QA) / 540 (prod) connections |
| Service-to-service | `WebClient` + `.block()` (booking-service alone has 142 `.block()` calls), Feign (`commons-cloud`, used by corporate/requester/gateway), Kafka for events |
| Cache | Redis already deployed and used (`CacheConfig`: reference data + profiles, 6h TTL) |
| Cluster (QA) | one k3s node: 4 CPU / 16 GiB, ~4% CPU, 52% memory. Pods use 350-650 MiB each (requests 200m/512Mi, limits 1 CPU/1Gi) |
| Autoscaling | HPA (CPU 80%, 1-3 replicas) on 7 services; **none** on booking-service and landlord-service |
| Observability | Prometheus + Grafana + Loki + Promtail running; `/actuator/prometheus` on every service; no tracing |

## 2. Findings, ranked by impact vs. risk

Status: **APPLIED** = done on a branch, config-only. **APPROVAL** = needs your OK (code change, dependency, behaviour or capacity risk).

### Tier 1 - high impact

**F1. DB connection held across remote calls (booking-service, all MVC services). APPROVAL**
- `spring.jpa.open-in-view` is the Spring default (`true`; no override anywhere). With it, a request keeps its DB connection until the response is written. booking-service also has `@Transactional` methods that call payment/landlord-service with `.block()` inside the transaction (`LandLordBookingService`: 19 `@Transactional`, 19 `.block()`; same in the other 5 booking classes).
- Risk under load: with a 10-connection pool, ~10 concurrent booking requests can exhaust it while they wait on another service; everything else on that service then queues for 30 s (`connection-timeout`) and fails.
- Fix: (a) `spring.jpa.open-in-view=false` (config, but may surface `LazyInitializationException` where DTO mapping touches lazy associations outside a transaction - needs a test pass), (b) move remote calls out of `@Transactional` where the logic allows (code).
- Benefit: the largest single increase in sustainable concurrency. Risk: medium (behaviour on lazy loading); do on QA with the load test.

**F2. Virtual threads. APPROVAL**
- Supported (Java 21, Boot 3.5). Helps the 8 MVC services, most of all booking-service (142 blocking WebClient calls pinning Tomcat threads). Gateway is reactive: no benefit.
- Pinning check: **0 `synchronized`** blocks in the services/commons/data module; the only ThreadLocal use is `RequestContextHolder`/`SecurityContextHolder` (fine per virtual thread). No custom thread pools except 2 executor uses in notification-service (review). Hikari/pgjdbc in the Boot 3.5 BOM use locks, not `synchronized`.
- Caveats: (1) virtual threads do **not** raise DB throughput - the 10-connection pool still caps it (see F1/F10). (2) Enabling the flag also switches `@Scheduled` to a concurrent scheduler: booking-service has 15 jobs that currently run one at a time. Set `spring.task.scheduling.simple.concurrency-limit=1` together with the flag to keep that. (3) Kafka listeners also move to virtual threads.
- Change: `spring.threads.virtual.enabled=true` (+ the limit above) in each MVC ConfigMap. Roll out booking-service first.

**F3. Downstream HTTP calls have no timeouts (booking, payment, landlord, requester, corporate). APPROVAL**
- `WebClient.builder().build()` = no response timeout; Reactor Netty's connect timeout is 30 s; `.block()` has no timeout. A hung downstream pins a Tomcat thread (and a DB connection, see F1) indefinitely. Only the gateway sets a (5 s) response timeout.
- Fix: per-service `WebClientConfig`: connect 5 s, response ~30 s (payments/settlement may need more), and `.block(Duration)` on the hot paths. It is code, and a slow-but-successful call would start failing, so it needs your decision on the numbers.

**F4. SSE streams poll the database per client (landlord-service). APPROVAL**
- `LocationService.availabilityStream`: every open Find Parking / Book Advance stream runs a geo SQL query every `pollSeconds` (mobile default 3 s, server floor 2 s) on `boundedElastic`. N users searching = N/3 queries per second against the shared 10-connection pool that REST also uses.
- Fix (code): one poll per distinct query shared by all subscribers, or a short (2-5 s) cache of the geo query; or raise the server-side minimum interval. High benefit, medium effort.

**F5. Autoscaling vs. un-locked schedulers. APPROVAL (important correctness risk)**
- ShedLock coverage: booking-service 8 of 15 `@Scheduled` locked; payment-service 2 of 5; landlord-service 1 of 3; **notification-service 0 of 3 (no ShedLock at all) - and it already has an HPA with max 3**.
- With >1 replica the un-locked jobs run on every pod (duplicate reminders/notifications/state transitions).
- So: **do not add HPA to booking-service/landlord-service** (the busiest) until their jobs are locked; add `@SchedulerLock` (code), and consider ShedLock for notification-service.

### Tier 2 - medium impact

**F6. Probes use the full composite health for both liveness and readiness. APPROVAL**
- `/actuator/health` includes DB/Redis/Kafka indicators; 3 s timeout x 3 failures. Under CPU saturation or a Redis/DB blip, pods are restarted exactly when load is highest (restart storm).
- `/actuator/health/liveness` and `/readiness` exist (verified on booking-service). Fix: point liveness at `/liveness`, readiness at `/readiness`. **Blocker:** gateway `SecurityConfig` permits only the exact `/actuator/health`, so the gateway needs `/actuator/health/**` permitted first (code), otherwise its probes get 401 and the pod is killed.

**F7. JVM memory not set in containers. APPROVAL**
- No `JAVA_TOOL_OPTIONS`/Dockerfile flags: max heap = 25% of the 1 GiB limit = ~256 MiB, while pods already use 350-650 MiB RSS. Under load that means frequent GC.
- Fix: `-XX:MaxRAMPercentage=60` via env in `apps/<svc>/values.yaml`. The node has ~7.7 GiB free, but raising the heap raises pod memory (OOMKill risk at the 1 GiB limit); decide together with the memory limit after the baseline run.

**F8. Gateway has no rate limiting, circuit breaker or response timeout. APPROVAL**
- Rate limiting (`RequestRateLimiter`) needs the reactive Redis dependency (Redis exists in the cluster, the gateway has no client); circuit breakers need Resilience4j. Both = new dependencies.
- A global `response-timeout` would cut the SSE streams that pass through the gateway; use per-route metadata instead. Pool `max-connections` is also unsafe for the same reason (long-lived SSE connections count toward it).
- No request-size limit at the gateway (services cap multipart at 10 MB / 50 MB).

**F9. Feign retries (commons-cloud `OpenFeignConfig`). APPROVAL**
- `Retryer.Default(100ms, 1s, 3)` retries on I/O errors for every method including POST (load multiplication + duplicate side effects), and no explicit Feign timeouts (defaults 10 s connect / 60 s read). In commons, so it needs a republish of commons-cloud and a rebuild of all services.

**F10. Database capacity. APPROVAL**
- db.t3.medium is burstable (CPU credits) with a connection limit of roughly 400. Prod worst case (9 x 20 x 3 = 540) can exceed it. Do **not** raise pool sizes. Options: RDS Proxy (new infra), a bigger/non-burstable class, a read replica (needs read/write routing in code).
- 353 Flyway scripts, 81 contain index creation; list endpoints are widely paginated (only 9 unpaged `findAll()` calls overall, in admin/corporate/landlord/notification - review whether the tables are large). Run `EXPLAIN` on the nearby/by-city geo queries during the load test.

**F11. HPA tuning. APPROVAL**
- Target is 80% of a **200m** request (= 160m, i.e. 16% of one core), so scale-out is triggered by small absolute load and there is no memory metric. Tune together with F7 and after the baseline.

### Tier 3 - lower impact / already fine

- Async work: notifications/events already go through Kafka (`booking-status-changed`); the remaining synchronous payment calls are consistency-critical and should stay in the request. No slow email/report work found in the request path.
- Caching: reference data and profiles are cached in Redis (6 h TTL). Candidate for a short-TTL cache: the nearby/by-city geo queries (see F4). Needs a code change.
- Graceful shutdown: Spring's default is already `graceful`.
- Tracing: none. Adding Micrometer Tracing/OpenTelemetry is a dependency (APPROVAL); Loki + Prometheus cover logs/metrics today.

## 3. Changes applied (config only, each its own commit, nothing pushed)

| # | Repo / branch | Change | Roll back |
|---|---|---|---|
| 1 | `Landers-App-Platform-Essentials` / `perf-audit` | Gateway ConfigMap (`postgres/`): `httpclient.connect-timeout=5000`, `pool.max-idle-time=15s` | remove the `spring.cloud.gateway.server.webflux.httpclient` block, re-apply ConfigMap, `kubectl rollout restart deploy/gateway-service` |
| 2 | `Landers-App-Platform-Essentials` / `perf-audit` | Chart default `terminationGracePeriodSeconds` 30 -> 45 | set back to 30 |
| 3 | all 9 service repos / `perf-latency-buckets` | `management.metrics.distribution.slo` buckets for `http.server.requests` | remove that block from `application.yml` |
| 4 | the 8 MVC service repos / `perf-latency-buckets` | `server.tomcat.mbeanregistry.enabled=true` (exposes `tomcat_threads_busy`) | remove the `server:` block from `application.yml` |
| 5 | `Landers-App-Platform-Essentials` / `perf-audit` | this document + `load-tests/qa-baseline.k6.js` | delete the files |

Why these are safe: none changes a request's result. #1 only affects connection setup/reuse between gateway and services (a 5 s connect limit; reused connections are retired 5 s before Tomcat's 20 s keep-alive). #3/#4 only add metrics. #2 only lengthens the maximum shutdown wait.

## 4. Load test (Step 3)

`load-tests/qa-baseline.k6.js` - read-only (no bookings/payments), QA only, 5 -> 25 -> 50 virtual users over 7 minutes against: Find Parking nearby-available (the hottest geo read), Book Advance by-city, requester profile. Thresholds: error rate < 1%, p95 < 800 ms (profile < 500 ms).
Run it **before** any further change and keep the `--summary-export` output; re-run with identical parameters after each change.
Watch in Grafana during the run: `histogram_quantile(0.95, sum by (le,application) (rate(http_server_requests_seconds_bucket[1m])))`, `hikaricp_connections_active / _pending / _timeout_total`, `tomcat_threads_busy`, `jvm_gc_pause_seconds`, container CPU/memory, and RDS CPU credits + connections.
**Not run yet:** k6 is not installed on this machine and the run would load the shared QA box the team also uses - it needs your go-ahead (and ideally a quiet window). No baseline numbers exist yet, so no change here has a measured effect.

## 5. Not verified

Nothing was load-tested; the benefit of every item is expected, not measured. The ConfigMap change is validated (YAML parses; property names checked against `spring-cloud-gateway-server-4.3.0` metadata) but was not applied to the cluster. Unit/integration suites of all 9 services pass with the application.yml changes.

## 6. Options (no changes made): gateway protection (F8) and database capacity (F10)

### F8 - gateway rate limiting, circuit breaking, timeouts
| Option | Needs | Cost / effort | Risk |
|---|---|---|---|
| **A. Per-user/IP rate limit** with Spring Cloud Gateway `RequestRateLimiter` | new dependency `spring-boot-starter-data-redis-reactive` in gateway-service; Redis is already in the cluster (`redis-db`) - the gateway ConfigMap even has the host set but no client; a `KeyResolver` bean (user id from the JWT, else IP) | ~1-2 days incl. tests; Redis becomes a gateway dependency (needs a fail-open policy) | wrong limits throttle real users (shared NAT/office IPs); start in "report only" (log, don't reject) |
| **B. Circuit breaker + fallback** with `CircuitBreaker` filter + Resilience4j | new dependency `spring-cloud-starter-circuitbreaker-reactor-resilience4j`; per-route config | ~1 day; fallbacks must be defined per route (what does an app get when booking-service is down?) | a too-eager breaker turns a slow period into an outage; needs tuning from the baseline |
| **C. Per-route response timeout** via route metadata `response-timeout` (not global) | no dependency; config only | hours | must exclude SSE routes (`/lands/*/stream`) - a short timeout would cut live availability streams |
| **D. Request size limit** at the gateway | config / small filter | hours | uploads go through the gateway (photos up to 10 MB each, 50 MB per request) |
Recommended order: C (cheap, no dependency) -> A in report-only mode -> B only for booking/payment routes after the F3 timeouts are in.

### F10 - database capacity (RDS `db.t3.medium`, single-AZ, no replica)
Facts: every service keeps its whole Hikari pool open (idle connections observed on QA: 81 = 9 x 10 + 1). Worst case with HPA max 3: 270 (QA) / 540 (prod) vs. a limit of roughly 400 on this class. Burstable CPU (credit balance 576 on 2026-10-11).
| Option | Needs | Cost | Risk |
|---|---|---|---|
| **A. Lower idle connections**: `hikari.minimum-idle` (e.g. 2) so idle services stop holding 10 each; max stays 10/20 | ConfigMap only | none | first burst after idle pays connection-setup latency; **safest first step** |
| **B. RDS Proxy** (connection pooling in front of RDS) | new AWS resource + endpoint change in 9 ConfigMaps; IAM/secret wiring | ~$ per vCPU-hour of the instance + 1-2 days | pinning with prepared statements/session state can reduce multiplexing; test with the app |
| **C. Bigger / non-burstable class** (e.g. `m6g.large` or `db.t4g.large` unlimited) | RDS modify (brief failover if Multi-AZ, otherwise reboot) | monthly cost roughly 1.5-3x | needs a maintenance window |
| **D. Multi-AZ** | RDS modify | roughly 2x instance cost | availability, not throughput |
| **E. Read replica** for read-heavy queries (search, listings) | new replica + read/write routing (second datasource, `@Transactional(readOnly=true)` routing) in code | highest effort (days) | replica lag: a just-created booking may be missing from a listing |
| **F. Short-TTL cache of geo search** (also fixes F4) | code only, Redis already available | 1-2 days | stale availability up to the TTL (2-5 s) |
Recommended order: A (free) -> measure with the baseline -> F -> B or C depending on whether connections or CPU credits are the limit.

## 7. QA baseline findings (2026-10-10) and follow-ups

Full numbers: `load-tests/results/baseline-before.md`. Short version: 50 virtual users, 0 errors, p95 203 ms / p99 399 ms overall, RDS CPU 26%, no Hikari waits.

### 7.1 New findings from the run
1. **The gateway saturates first** - 64% average / 93% peak of its 1-CPU limit at ~50 req/s.
2. **`UserStatusFilter` (gateway) calls `GET /api/v1/users/auth/status/{userId}` on every authenticated request, uncached.** user-service received ~147 req/s for 49 req/s at the gateway (about 3 calls per request - worth checking why it is more than 1; the filter may be registered twice in the chain). This is also the busiest consumer of user-service CPU (up to 42%) and of its DB pool (6 of 10 active). Candidate fix (code, approval): cache the status per user for a few seconds and/or fix the duplicate invocation.
2b. Nothing else came close: landlord-service peaked at 32% CPU, 6/10 DB connections; booking/payment barely used.
3. **Live QA bug, not caused by the test:** the ConfigMap `user-service-config` on QA is still the old MySQL one (`jdbc:mysql://mysql-db...`, created 2026-07-24, never updated); the other 8 service ConfigMaps are Postgres. The one old user-service pod keeps working; **every newly started user-service pod crash-loops** ("Communications link failure", Flyway/MySQL). The HPA scaled user-service 1 -> 3 after the ramp and the 2 new pods are in CrashLoopBackOff; a normal restart or rollout of user-service would take down login/auth-status for everyone. The correct file exists in the repo: `landers-app-config-maps/postgres/user-service-configmap.yaml`.

### 7.2 Commands for you to apply (I have not applied anything), in this order
```bash
# on the QA box (ubuntu), from a checkout of Landers-App-Platform-Essentials at the branch you want
# 1. FIRST: fix user-service (otherwise any scale-out/restart of it fails). Then check the new pods become Ready.
kubectl apply -f landers-app-config-maps/postgres/user-service-configmap.yaml
kubectl rollout restart deployment/user-service && kubectl rollout status deployment/user-service
# 2. Gateway tuning (connect timeout + idle limit); gateway has 2 replicas now, so the restart is rolling
kubectl apply -f landers-app-config-maps/postgres/gateway-service-configmap.yaml
kubectl rollout restart deployment/gateway-service && kubectl rollout status deployment/gateway-service
# 3. Latency buckets + Tomcat metrics: ship by merging the perf-latency-buckets branches through the normal CI/ArgoCD flow
# 4. Chart grace period: merge perf-audit (ArgoCD syncs it)
```
Roll back: `kubectl apply -f` the previous version of the ConfigMap from git (`git show <commit>^:path | kubectl apply -f -`) and restart the deployment.

### 7.3 Proposal (NOT applied): `spring.datasource.hikari.minimum-idle`
- Evidence: RDS holds a flat **81 connections** at idle (9 services x 10 + 1); at 50 virtual users the busiest pools peaked at 6 active. Hikari keeps `minimum-idle` = `maximum-pool-size` by default, so every service holds its whole pool open forever. With HPA max 3 and prod pools of 20, that is up to 540 idle connections against a limit of ~400 on `db.t3.medium`.
- Change (ConfigMap, per service, qa and prod): `spring.datasource.hikari.minimum-idle: 2` (maximum-pool-size unchanged; idle connections above 2 are retired after `idle-timeout`, 10 min by default - prod already sets 600000).
- Expected: ~70 fewer idle connections on QA (~160+ on prod), more headroom for autoscaling, no change to peak capacity.
- Risk: low. The first burst after a quiet period opens connections on demand (a few ms to tens of ms each over TLS to RDS). Roll back: remove the line, restart the service.
- Needs the services restarted to take effect. Suggest: one service first (e.g. requester-service), watch `hikaricp_connections` and RDS `DatabaseConnections`, then the rest.

## 8. Item 2d - service-to-service timeouts: PROPOSAL (nothing applied; approve the list)

### 8.1 What exists and what the baseline can tell us
- Today **no** inter-service call has a timeout except the gateway's outbound client (5 s response timeout, no connect timeout - the connect timeout is now set by the gateway ConfigMap commit) and one gateway call in `AppBuildPolicy`. Reactor Netty's own connect timeout is 30 s; `.block()` waits forever.
- The baseline only exercised `gateway -> user-service` (status check, ~3 ms average on the server) and the landlord-service reads that the gateway serves directly (k6 end-to-end p99 <= 474 ms at 50 virtual users, of which the call itself averaged 14 ms). **It did not call booking->payment, payment->booking, anything->admin, Paymob or the Feign clients**, so there is no measured p99 for those downstreams yet. The numbers below are therefore conservative; once the latency-bucket commits are deployed and the booking/payment flows have been exercised, tighten each to roughly 3x the observed p99.

### 8.2 Proposed values (connect / response), where "response" = time to the full response
| Caller -> downstream | Calls | Proposed connect / response | Notes |
|---|---|---|---|
| gateway -> user-service status check (`UserStatusFilter`) | GET | keep 5 s (set) / connect 5 s (done) | measured avg 3 ms; could drop to 2 s once cached |
| gateway -> user/corporate/notification (registration, OTP) | POST/GET/PATCH | keep 5 s; OTP send may need longer - check Wapilot latency before changing | registration is a saga with compensation |
| booking -> landlord-service | GET x5 (spot validation), PATCH x2 (spot status) | 3 s / 10 s | PATCH is a state change but idempotent (set status) |
| booking -> requester-service | GET x3, POST x1 (eligibility) | 3 s / 10 s | reads |
| booking -> corporate-service | GET x3 | 3 s / 10 s | reads |
| landlord / requester / corporate -> admin-service | reads and `POST .../validate`, `.../bulk` (read-only lookups) | 3 s / 10 s | reference data, cached on the admin side |
| payment -> corporate-service | GET x2 | 3 s / 10 s | reads |
| payment -> booking-service (`notifyPaymentConfirmed/Cancelled`) | PUT x2 | 3 s / 15 s | state notification after money moved - **review individually** |
| payment -> Paymob (external HTTPS) | POST `createIntention`, `refund` | 5 s / 30 s | third party; slowest legitimate call in the system; **review individually** |
| booking -> payment-service reads | GET `getMyBalance` | 3 s / 10 s | read |

### 8.3 Payment-related calls - need your individual decision
`booking -> payment-service` POST x10: `settle`, `settleSplit`, `collectCashFee`, `chargeOnlineFee`, `chargeTimerStartFee`, `refundCancellation`, `holdBookingEscrow`, `releaseBookingEscrow`, `recordEarningsEntry`, `settleEarningsCash`.
- **Hazard:** none of the payment-service endpoints I looked at (`settleBooking`, `holdBookingPayment`, `settleSplitBooking`, `releaseBookingEscrow`) de-duplicates by booking (no idempotency key / existing-transaction check). Callers treat an exception as "not charged" (e.g. `settle` returns null and the caller deliberately does not advance `amountPaidSoFar` "so the delta can be retried"). A client **response timeout** can fire after payment-service has already committed, turning a slow success into a retried charge.
- **Recommendation:** for these 10 calls set only a **connect timeout (3 s)** - safe, the request was never sent - and **no response timeout** (or a long one, 60 s, only as a thread-leak backstop) until either payment-service accepts an idempotency key per call, or the callers learn to treat a timeout as "unknown, reconcile" instead of "failed". That is a code change in two services and needs a separate decision.
- The Feign retry fix (item 2b) already removed the other way a payment POST could be repeated.

### 8.4 How it would be applied (after you approve the table)
Per service `WebClientConfig`: build the `WebClient` on a Reactor Netty `HttpClient` with `CONNECT_TIMEOUT_MILLIS` and `responseTimeout`; calls that need different values use `.timeout(Duration)` on the individual `Mono`. Blocking `.block()` calls in `booking-service` get `.block(Duration)` with the same value. Repos touched: booking, payment, landlord, requester, corporate (+ gateway only for the missing connect timeout, already done in config). No behavior change except that a call that exceeds the limit now fails instead of hanging.
