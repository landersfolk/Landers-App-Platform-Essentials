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
- `WebClient.builder().build()` = the JDK HttpClient: no connect timeout, no response timeout; `.block()` has no timeout. A hung downstream pins a Tomcat thread (and a DB connection, see F1) indefinitely. Only the gateway sets a (5 s) response timeout.
- Fix: per-service `WebClientConfig`: connect 5 s, response ~30 s (payments/settlement may need more), and `.block(Duration)` on the hot paths. It is code, and a slow-but-successful call would start failing, so it needs your decision on the numbers.

**F4. SSE streams poll the database per client (landlord-service). APPROVAL**
- `LocationService.availabilityStream`: every open Find Parking / Book Advance stream runs a geo SQL query every `pollSeconds` (mobile default 3 s, server floor 2 s) on `boundedElastic`. N users searching = N/3 queries per second against the shared 10-connection pool that REST also uses.
- Fix (code): one poll per distinct query shared by all subscribers, or a short (2-5 s) cache of the geo query; or raise the server-side minimum interval. High benefit, medium effort.

**F5. Autoscaling vs. scheduled jobs. RESOLVED - corrected on 2026-10-11 (no action needed).**
- The first version of this finding was wrong: I counted text matches of `@Scheduled`/`@SchedulerLock` (which included comments). Counting actual annotated methods: **booking-service 8 of 8 jobs are locked, payment-service 2 of 2, landlord-service 1 of 1.** Only notification-service has no locking (3 jobs, no ShedLock dependency), and its jobs are idempotent single SQL statements (`bulkExpirePending`, `deleteByCreatedAtBefore`, and a no-op), so running them on every replica is harmless duplicate work. Locking them would need the ShedLock dependency added to that service and is not required for correctness.
- See section 12.2: the shared lock name between `StaleSessionCompletionScheduler` and `OverstayRolloverScheduler` is **deliberate** (my first reading, a copy-paste slip, was wrong); the open question is whether it starves one of them.
- Therefore HPA on booking-service/landlord-service is not blocked by scheduling. It is still not applied (capacity/DB-connection decision, see F10/F11).

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

## 9. Plans after the baseline (no changes made)

### Item 7 - JVM memory (F7): the baseline does not support raising the heap
- At 50 virtual users the **maximum heap in use was 65-94 MB per service against a ~256 MB default maximum**, and total GC pause time over 7.4 minutes was 0.01-1.3 s (gateway 1.29 s, user-service 1.08 s, landlord 0.68 s, the rest below 0.1 s). The gateway's GC time is the only value worth watching.
- Plan: do **not** change `MaxRAMPercentage` now. Re-measure at higher load after the status-check amplification is fixed; raise the heap only if heap use gets near ~70% of the maximum or GC pauses exceed ~5% of run time. Revisit with the memory limit at the same time. What the numbers *do* point at is CPU (item below), not memory.

### What the baseline points at instead (candidate next steps, all need your OK)
1. **Gateway CPU (93% of its 1-CPU limit at ~50 req/s).** Cause candidates: JWT validation + routing + the per-request status call to user-service (about 3 per request, uncached). Plan: find why the filter fires ~3 times per request (registered twice?), then cache the status for a few seconds. Expected: the single biggest CPU and latency win, and ~2/3 less load on user-service.
2. **CPU request/limit for the gateway** (request 200m / limit 1 CPU, HPA at 80% of the request): the autoscaler reacted only after the run. A higher request (e.g. 500m) with the same limit makes the HPA scale on real load. Config only, but it changes pod scheduling on the shared QA node.

### Item 4 - SSE availability streams polling the DB (F4)
- Not covered by the baseline (it opened no streams). Plan: (1) add a k6 scenario that opens N concurrent `nearby/available/stream` and `by-city/stream` connections for a few minutes with the existing read-only account and measure `hikaricp_connections_active`, landlord-service CPU and query rate at N = 10 / 50 / 100; (2) based on that, choose between: a server-side minimum poll interval (config/small code), one shared poll per distinct query key with fan-out (code, medium), or a short-TTL cache of the geo query (code, small). Nothing is changed until the measurement exists.

## 10. Items 1 and 2 - booking-service transactions, connections and open-in-view: ANALYSIS ONLY (no code changed)

### 10.1 What `open-in-view` does today
`spring.jpa.open-in-view` is the Spring default (`true`, no override). For every web request an `EntityManager` stays open until the response is written; if the request reads from the DB **outside** a transaction, the JDBC connection it acquired stays checked out until then. Inside an `@Transactional` method the connection is held for the whole transaction, with or without open-in-view. So there are two separate problems; turning open-in-view off fixes only the first:

| # | Problem | Fixed by `open-in-view=false`? |
|---|---|---|
| A | Non-transactional read, then slow work (remote calls, JSON mapping) in the same request keeps the connection | **yes** |
| B | `@Transactional` method that makes a remote call keeps the connection for the duration of the call | **no** - needs the method restructured |

### 10.2 Remote calls made inside a transaction (problem B) - booking-service
Static scan of `booking-service` (method level, following same-class calls): **130 `@Transactional` methods, of which 100 reach a remote call** (`WebClient` `.block()`, or a helper that calls other services: `SpotOwnerResolver` -> landlord/corporate, `PlatformFeeRateResolver` -> requester/landlord/corporate, `BookingActorGuard` -> corporate permissions).
| Class | tx methods | of which reach a remote call |
|---|---|---|
| LandLordBookingService / CorporateBookingService | 18 / 18 | 15 / 15 |
| LandLordLandingService / CorporateLandingService | 18 / 18 | 16 / 16 |
| LandLordQuickStopService / CorporateQuickStopService | 18 / 18 | 16 / 16 |
| BookingRolloverService, OverstayRolloverScheduler, NoShowScheduler, BookingReminderScheduler, CorporateRevenueService | 2, 1, 1, 1, 1 | all |
Representative flows in `LandLordBookingService` (the others mirror it): `createBooking` (landlord-service, requester-service, fee rates), `acceptBooking`/`rejectBooking`/`cancelBooking` (landlord-service, **payment-service**), `payBooking` (**payment-service** escrow hold), `checkIn` / `checkOut` / `confirmPayment` / `confirmCashReceived` (landlord-service, **payment-service**, fee rates, corporate permissions). In each, the DB connection is checked out while those calls run, which is exactly why a slow or unreachable downstream exhausts the 10-connection pool.
Schedulers are not web requests, so open-in-view does not apply to them, but the same transaction-holds-connection rule does.

### 10.3 Non-transactional reads that call other services (problem A) - the feed endpoints
`getMyBookingsFeed`, `getOwnedBookingsFeed`, `getBookingsByStatus` (and the same trio for landings, quick stops and the corporate variants) read a page from the DB, then `toKeysetPage` -> `enrichFloorLabels` and `enrichRequesterNames` call landlord-service / requester-service **one blocking call per distinct requester and per distinct floor spot, sequentially**. A page defaults to 5 rows (max 100), so a landlord's busy feed can mean up to 100 sequential remote calls with the connection and the Tomcat thread held. These are the hottest read endpoints of the Business app. Two separate improvements: batch the lookups (one bulk call instead of N; `admin-service` already has `/bulk` lookups as a model) and run them in parallel - both code changes, independent of open-in-view.

### 10.4 Lazy loading that depends on open-in-view
Much narrower than feared: booking-service has **no `@ManyToOne` / `@OneToMany` at all** (the entities reference other services by id). The **only lazy association is `@ElementCollection List<LandLandingVehicle> vehicleIds`** on `LandLordLanding`, `CorporateLanding`, `LandLordQuickStop`, `CorporateQuickStop`. It is read by the four MapStruct mappers (`extractPrimaryVehicleId`). Every service method that maps one of these entities to a DTO **without being `@Transactional`** would throw `LazyInitializationException` once open-in-view is off:
| Service | non-transactional methods that map a landing / quick-stop entity |
|---|---|
| LandLordLandingService | getLandingById, getLandingsByUser, getMyLandingsFeed, getLandingsByLandSpot, getLandingsByStatus, getOwnedLandingsFeed (+ doReject) |
| CorporateLandingService | the same set without the "my feed" |
| LandLordQuickStopService / CorporateQuickStopService | the equivalent set |
= **26 methods** (the 4 `doReject` are probably only reached from transactional callers - verify). Standard bookings (`LandLordBooking`, `CorporateBooking`) have no lazy association, so they are not affected.

### 10.5 Risk of turning it off, and the smallest safe change
- Risk: 500s on the ~22 landing / quick-stop read endpoints the first time they map a row with `vehicleIds`; nothing else in this service depends on the open session.
- Smallest change that keeps behavior: (1) mark those 26 methods `@Transactional(readOnly = true)` (or give the finders an `@EntityGraph(attributePaths = "vehicleIds")` / make the collection eager - it is a tiny list), (2) set `spring.jpa.open-in-view=false`. Keep the 100 transactional+remote methods as they are in this step; restructuring them (prepare in a transaction -> call without a connection -> commit in a second transaction) changes failure semantics (today a failed remote call rolls back the DB writes) and should be a separate decision, flow by flow, starting with `payBooking`/`checkOut`.
- Expected benefit of step (1)+(2) alone: removes problem A (feeds) only; problem B (the payment/landlord calls inside transactions) is untouched. Be careful not to oversell it.

### 10.6 Tests that would cover it (Docker is available here, `testcontainers` is already a booking-service test dependency; existing tests: 7, none touch this)
1. `OpenInViewDisabledMappingIT` (Postgres container, `spring.jpa.open-in-view=false`): create a landing / quick stop per service with 2 vehicles, call each of the 26 read methods from a non-transactional thread, assert no `LazyInitializationException` and `vehicleId` populated. **Fails today for the unannotated methods, green after the change** - this is the regression net.
2. `ConnectionNotHeldDuringRemoteCallIT`: stub the payment client with a latch; start `payBooking` / `checkOut` / `createBooking` on a thread; read `HikariPoolMXBean.getActiveConnections()` while blocked. Documents problem B per flow (1 active today); becomes 0 only after the restructure.
3. `PoolExhaustionIT`: pool size 2, 6 concurrent `payBooking` with a slow stubbed payment client; assert how many complete within the pool timeout - the before/after proof for any restructure.
4. For the feeds: a test that counts remote calls per page (expect 1 bulk call, today N).

### 10.7 Could a more realistic load test show the pool problem?
Yes, but not by volume alone: at the baseline's rates a booking call holds a connection for ~10-50 ms, so exhausting 10 connections needs hundreds of booking operations per second. The pool problem appears when **a downstream is slow or down**. What it needs:
- **Data:** seed realistic lands/spots on QA (e.g. 200 lands x 10 spots across 3-4 cities) with a test landlord via the API (+ admin approval), or a QA-only SQL seed. Today QA has 2 lands near Cairo.
- **Accounts:** ~50 requester accounts with funded wallets and a few landlord/corporate accounts to accept (accounts need OTP registration, so a one-off provisioning step by you); all with **no device tokens**, so no real push is sent.
- **Scenario (QA only, wallet payment = internal, no real money; card/Paymob stays out):** create booking -> owner accepts -> `payBooking` (escrow hold) -> arrive -> check-in -> check-out, one spot per virtual user so spot state does not collide; plus the read-only browse mix. Clean-up script afterwards (cancel/delete the test bookings, restore wallets).
- **The experiment that exposes the pool:** run the scenario at ~5 flows/s while payment-service is made slow or unavailable (scale it to 0 for 2 minutes, or inject latency) - with the new 3 s connect timeout each blocked call now holds a connection for 3 s, so ~4 concurrent flows already saturate a pool of 10; before the timeouts it would hang until the OS gives up. Needs your explicit go-ahead because it deliberately degrades QA.
- **Observe:** `hikaricp_connections_active/pending/timeout_total` and `tomcat_threads_busy` on booking-service, p95 of the booking endpoints, 5xx.

## 11. UserStatusFilter - why user-service receives ~3x the gateway's rate: ANALYSIS + PROPOSAL (no code changed)

### 11.1 Cause (reproduced)
`UserStatusFilter` calls `GET user-service /api/v1/users/auth/status/{userId}` on every authenticated request, uncached. It is amplified two ways:
1. It is registered **twice**: it is a `@Component implements WebFilter` (WebFlux adds every such bean to the main filter chain) **and** `SecurityConfig` adds the same instance with `addFilterAfter(userStatusFilter, AUTHENTICATION)`. Each request passes it twice.
2. Inside the filter, `.flatMap(... chain.filter(exchange))` yields a `Mono<Void>`, which is **empty on completion**, so the trailing `.switchIfEmpty(chain.filter(exchange))` fires and **re-runs the rest of the chain** a second time per registration. (The gateway's `NettyRoutingFilter` skips re-routing an already-routed exchange, which is why the backends still see each request once - the landlord-service request rate equals the k6 iteration rate.)
Reproduced with a throwaway harness wiring the real filter the way the gateway does: **2 registrations -> 3 user-service calls (and 4 passes through the downstream handler) per request; 1 registration -> 1 call (2 passes)**. Measured on QA: 147 status calls/s for 49 requests/s = 2.9x. The harness was not committed.

### 11.2 Proposal, in two steps
**Step A - remove the amplification, no behavior change.** (a) Register the filter once (drop `addFilterAfter` or make the bean not a global `WebFilter`; the status check needs the authenticated context, so keep the security-chain registration and remove the `@Component` auto-registration). (b) Replace the `flatMap(...).switchIfEmpty(chain.filter)` shape with `...map(a -> true).defaultIfEmpty(false).flatMap(authenticated -> authenticated ? check(...) : chain.filter(exchange))` so the chain runs exactly once. Result: 3 calls -> 1 per request (-67% load on user-service), the redundant chain re-runs disappear (likely a visible share of the gateway's CPU), semantics identical (same status check, same fail-open rules). Add the harness as a permanent regression test. Risk: low.
**Step B - cache the answer (behavior change, your decision).** In-memory per gateway pod, key = business user id, bounded (e.g. 10,000 entries), no new dependency (a `ConcurrentHashMap` with expiry, or Reactor `Mono.cache(ttl)` per key).
| Choice | Effect on a blocked/suspended user | Load reduction on user-service |
|---|---|---|
| cache only `ACTIVE`, TTL 5 s | keeps working for up to 5 s after being blocked (per gateway pod) | calls per user capped at 1 per 5 s: at 50 req/s from one user 250x fewer; for a typical user (a few requests per minute) mostly 1 call per screen burst |
| TTL 15 s | up to 15 s | more |
| TTL 60 s | up to 60 s (too long for a safety control, in my view) | most |
| non-ACTIVE results never cached | a blocked user is re-checked on every request (blocked stays blocked immediately); an **un**blocked user is let through at once | unchanged for blocked users, who are rare |
| + event-based eviction | user-service already publishes to Kafka; a `user-status-changed` event evicts the entry on every gateway pod -> effectively **0 s staleness** with a long TTL | needs code in user-service and the gateway (Kafka consumer) |
Fail-open on user-service errors stays as it is. Recommendation: Step A now; then Step B with "ACTIVE only, 10 s TTL, non-ACTIVE never cached" and measure; add event-based eviction only if the security team wants zero staleness. With HPA the gateway runs 1-3 pods, so "up to TTL" applies per pod and a status change is felt within TTL everywhere.

## 12. Findings for the team

### 12.1 No payment endpoint de-duplicates by booking - proposed idempotency-key design
**Finding.** `WalletService.settleBooking`, `holdBookingPayment`, `settleSplitBooking`, `releaseBookingEscrow` (and the fee endpoints behind `collect-cash-fee`, `online-fee`, `timer-start-fee`, `refund-cancellation`) apply the movement every time they are called; there is no existing-transaction check by booking id, no unique constraint and no idempotency key. The callers (booking-service) treat "no response" as "not charged" and some deliberately retry later (`settle` returns null and `amountPaidSoFar` is not advanced "so the delta can be retried"). So any repeated delivery - a client timeout after the commit, a Feign retry (fixed for non-GET in 2b), a double tap that slips past the row lock, a restarted caller - can charge or credit twice.
**Design.**
1. *Contract:* each money-moving endpoint accepts an `Idempotency-Key` header (a UUID or a deterministic string, <= 80 chars). Missing header = today's behavior (so rollout is backward compatible).
2. *Storage (needs a Flyway migration - a schema change, hence approval):* table `payment_idempotency(key text primary key, operation text, request_hash text, status text -- IN_PROGRESS|COMPLETED, response_json jsonb, wallet_owner_type text, created_at timestamptz, completed_at timestamptz)`; index on `created_at` for the sweep.
3. *Flow inside the payment-service transaction, before touching any wallet:* `INSERT` the key. On a unique-violation, read the stored row: `COMPLETED` and same `request_hash` -> return the **stored response unchanged** (no second movement); `IN_PROGRESS` -> 409 (the first attempt is still running; the caller retries after a short delay); same key but different hash -> 422. After the wallet changes, store the response and mark `COMPLETED` in the **same transaction** as the movement, so a crash leaves neither or both (atomic).
4. *Key derivation in booking-service (deterministic, so a retry reuses it):* `hold:{bookingId}`; `release:{bookingId}:{reason}`; `refund:{bookingId}:{kind}`; `settle:{bookingKind}:{bookingId}:{amountPaidSoFarBefore}` (the delta being settled makes each overstay increment unique); `fee:{operation}:{bookingKind}:{bookingId}`. The caller never invents a random key per attempt.
5. *Then* payment calls can safely get a response timeout and automatic retry with the same key (the exact thing section 8.3 had to forbid today); a timeout becomes "unknown - retry with the same key".
6. *Housekeeping:* delete keys older than 30 days from a ShedLock-protected job. Keep the Paymob webhook as is (it already keys on the order).
**Rollout:** (1) payment-service accepts the optional header + migration; (2) booking-service sends keys; (3) enable response timeouts + retry for payment calls; (4) later, optionally require the header.
**Tests:** duplicate request returns the first response and moves money once; two concurrent duplicates -> one executes, the other 409 then the same response; same key + different payload -> 422; crash between insert and commit leaves nothing; every caller's key derivation is stable across retries.
**Risks:** a wrongly derived key either blocks a legitimate second operation (too coarse) or fails to protect (too fine); table growth (sweep); 409 handling in callers. Effort: roughly 3-5 days incl. tests across two services.

### 12.2 booking-service: two scheduled jobs share one lock name (deliberate) - possible starvation
**Finding.** `OverstayRolloverScheduler.overstayAndRolloverSweep` and `StaleSessionCompletionScheduler.completeStaleSessions` both use `@SchedulerLock(name = "booking-overstayAndRolloverSweep", lockAtMostFor = "PT2M", lockAtLeastFor = "PT10S")`. This is **intentional** (commit `3918c24`, 2026-10-03: "so the two jobs never process the same booking"; the code comment says "Deliberately the SAME lock name"). With `lockAtLeastFor = 10 s`, whichever job runs first keeps the lock for at least 10 s after it starts. Both are `fixedDelay` 60 s jobs on the same single-threaded scheduler, so the second one starts milliseconds later, finds the lock held and is skipped; 60 s later the same order repeats - so the second job may **never run**. Evidence is circumstantial: 8,928 log lines for the overstay sweep in 24 h on QA vs. 0 for `StaleSessionCompletion` (that job only logs when it closes a session, so it proves nothing by itself).
**How to confirm (read-only):** (1) `SELECT name, locked_at, lock_until, locked_by FROM shedlock WHERE name = 'booking-overstayAndRolloverSweep'` repeatedly and see whether `locked_at` advances once or twice per minute; (2) count `ACCEPTED` sessions that are checked in, not checked out, and past `end_time + 10 min` - if any exist, the completion job is not running; (3) temporarily log `net.javacrumbs.shedlock` at DEBUG for 5 minutes ("Not executing ... It's locked").
**Options.** (a) Keep mutual exclusion but run both from **one** scheduled method (overstay sweep, then the completion sweep) under one lock - no starvation, same exclusion; (b) separate lock names plus the row-level re-check that already exists (the commit says both jobs re-check under a row lock) - simplest, but the author chose a shared lock on purpose, so ask first; (c) lower `lockAtLeastFor` to ~1 s - narrows but does not remove the window. Option (a) is my recommendation. Either way the change enables a job that may have been idle, so test it on QA data first (it would close stale sessions at their booked end time).
