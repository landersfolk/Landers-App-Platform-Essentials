# Vault → Infisical secrets migration (2026-08-06 → 2026-08-07)

**Status: 100% COMPLETE on BOTH clusters.** All 9 backend services
(gateway/admin/requester/landlord/corporate/user/booking/payment/notification-service)
are fully cut over to Infisical for secrets management on both `main` (dev,
k3d-landers-app) and `quality` (QA, EC2 box `i-0285595f45e8d9f7d`, cluster
name `landers-qa`) — confirmed `Healthy`, 0 restarts, on both. Vault itself is
no longer just disabled — the Vault server infrastructure has been **deleted**
from both clusters (see "Vault server removal" below).

## Why

Vault's own `secret/landers-app/<service>` KV paths were empty on every
service, on both clusters, apparently always had been — nothing was actually
reading real secrets from Vault in practice even before this migration.
Infisical Cloud replaces it as the actual secrets source of truth going
forward.

## What changed

| Before | After |
|---|---|
| `spring-cloud-starter-vault-config`, `optional:vault:` import in every service's `application.yml` | Removed entirely from commons-cloud's pom.xml and every service's `application.yml` |
| Vault KV paths `secret/landers-app/<service>` | Infisical Cloud project `91adb2cf-e59c-44bb-9b8e-847e2c5e26ad`, organized into per-domain folders: `/DB`, `/KEYCLOAK`, `/S3` |
| `vault:` block in `apps/<service>/values.yaml`, `vault.enabled: true` | `vault.enabled: false` everywhere (block left in place, not deleted, as a rollback path) + new `infisical:` block |
| `vault-server` (local, dev-mode, no persistent data) / `vault-prod` (QA, real HA StatefulSet + 10Gi PVC) | Both deleted entirely |

## New commons-cloud component: `InfisicalEnvironmentPostProcessor`

`commons-module/commons-cloud/src/main/java/io/landers/commons/cloud/config/InfisicalEnvironmentPostProcessor.java`
— a Spring Boot `EnvironmentPostProcessor` (registered via `META-INF/spring.factories`,
runs during environment preparation, same lifecycle slot the old
`optional:vault:` import used). At startup, authenticates to Infisical via
Universal Auth (`INFISICAL_CLIENT_ID`/`INFISICAL_CLIENT_SECRET`, sourced from
a k8s Secret — never committed to git), fetches secrets from three folders,
and injects them into the Spring `Environment`:

| Folder | Keys | Aliased to |
|---|---|---|
| `/DB` | `DB_USERNAME`, `DB_PASSWORD`, `FLYWAY_USERNAME`, `FLYWAY_PASSWORD` | `spring.datasource.*`, `spring.flyway.*` |
| `/KEYCLOAK` | `ADMIN_CLIENT_ID`, `ADMIN_CLIENT_SECRET`, `CLIENT_ID`, `CLIENT_SECRET` | `keycloak.adminClientId`/`adminClientSecret`/`clientId`/`clientSecret` |
| `/S3` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `media.upload.s3.access-key`/`secret-key` |

The non-secret Keycloak fields (`auth-server-url`, `realm`, `tokenUrl`) still
come from the ConfigMap, unchanged — only the two client secrets moved to
Infisical.

Each folder is fetched independently (its own try/catch) — a folder that
doesn't exist yet or is misnamed doesn't take down the folders that do. This
caught a real bug during development: the S3 credentials were first coded to
look under `/AWS`, which silently 404'd and was swallowed by this same
resilience — found by actually testing a real S3 put/get/delete round-trip
inside a running pod, not just trusting the code. The folder is actually
named `/S3`, despite the `AWS_`-prefixed key names inside it.

`INFISICAL_HOST`/`INFISICAL_PROJECT_ID`/`INFISICAL_ENV` are all **required**,
sourced only from the Helm chart's `infisical.*` values
(`charts/landers-app/values.yaml` → `templates/deployment.yaml` env vars) —
deliberately no hardcoded fallback in the Java code. A silently-defaulted
`INFISICAL_ENV` (e.g. defaulting to `"prod"`) would risk a misconfigured
dev/local service silently fetching prod secrets instead of failing loudly;
if any of the 5 required values (client id/secret/host/project-id/env) is
missing, the fetch is skipped entirely with a warning log, not guessed.

## S3 credentials: role-first, environment-gated

`commons-storage`'s `StorageAutoConfiguration.credentialsProvider()` already
had a role-first design (EC2 instance/service role, falling back to static
keys only when no role is available). The static-key fallback is now also
**hard-gated on the active Spring profile** — `qa`/`prod` never consult the
static keys at all, even if `media.upload.s3.access-key/secret-key` happen to
be set, closing a latent risk where a misconfigured or leaked static key
could otherwise have been used outside local dev. The `/S3` Infisical
credentials only ever matter on hosts with no instance role, i.e. the local
k3d cluster — QA/prod's S3 access is unchanged, still purely role-based.

## Infisical environment slugs per cluster

- **`main` (local k3d)**: `INFISICAL_ENV=dev`
- **`quality` (QA EC2)**: `INFISICAL_ENV=staging` — verified `/DB` and
  `/KEYCLOAK` secrets already existed under this slug before wiring it in;
  no `/S3` secrets exist under `staging` (correct/expected, since QA is
  role-only for S3 per the gating above).

## `quality` branch note

`quality` was **not** just "`main` plus more commits" for this migration —
`commons-module`'s `quality` branch had zero Infisical work and still had the
raw Vault dependency when this started. The relevant commits (isolated to
`commons-cloud`/`commons-storage`/each service's `application.yml`, confirmed
via diff before touching anything) were cherry-picked cleanly onto `quality`
with `mvn clean install`/`compile` verified before every push — same pattern
as [[feedback_verify_cherry_pick_compiles_2026_08_01]] in Claude's memory.
Each service's own `apps/<service>/values.yaml` needed hand-editing rather
than cherry-picking on `quality`, since QA uses real per-service Vault
**APPROLE** auth (`host: vault-prod`) vs local's shared **TOKEN** auth
(`host: vault-server`) — cherry-picking the original commit would have
clobbered QA's own auth block.

QA's own ConfigMap tree (`landers-app-config-maps/postgres/`, the
RDS-hostname QA-specific tree, distinct from the plain top-level one used
locally) already had Redis correctly wired for every service in every
profile — no config gaps there, unlike local dev which needed a real fix in
4 services (booking/payment/notification/gateway — `commons-cloud` itself
transitively pulls in `spring-boot-starter-data-redis`, so *every* service
gets a Redis health indicator autoconfigured regardless of whether that
service's own code touches Redis; missing `spring.data.redis.host` meant a
permanent `503` on the combined `/actuator/health` used by k8s probes).

ArgoCD on QA lagged noticeably behind local in picking up new commits — a
manual `argocd.argoproj.io/refresh=hard` annotation (via SSM, see below) was
needed repeatedly rather than waiting for the poll interval. Always verify
actual pod `startTime`/image after a push here, don't trust `Synced` status
alone.

## QA access pattern

No local kubeconfig exists for the QA cluster — access is via SSM:

```bash
aws ssm send-command --instance-ids i-0285595f45e8d9f7d \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo k3s kubectl get pods -n default"]'
# then: aws ssm get-command-invocation --command-id <id> --instance-id i-0285595f45e8d9f7d
```

For an interactive session: `aws ssm start-session --target i-0285595f45e8d9f7d`.
The QA box's own browser terminal (if used directly) mangles multi-line/
backslash-continuation commands — keep commands single-line there.

## Vault server removal (final step)

Investigated both clusters' actual Vault footprint before deleting anything,
since the risk differed sharply:

- **Local**: `deployment/vault` + `service/vault-server`, **no PVC at all** —
  dev-mode Vault, no persistent data. Low-risk deletion.
- **QA**: `statefulset/vault-prod` + `service/vault-prod` +
  `service/vault-prod-internal` + a real bound **10Gi PVC**
  (`data-vault-prod-0`) — actual persisted data, permanently lost on
  deletion. Confirmed with the user before deleting this specifically (no
  backup taken, per their explicit call).

Confirmed no other dependents first: every `apps/*/values.yaml`'s
`vault-server`/`vault-prod` references are only the now-inert
(`enabled: false`) `vault:` block's `host:` field, never rendered into the
Deployment template anymore; frontends (`admin-dashboard`, `lander-web`)
never had `vault.enabled: true` to begin with.

Deleted local's deployment+service directly. Deleted QA's statefulset + 2
services + PVC via SSM (`kubectl delete` × 4 — PVCs from StatefulSets are
never auto-deleted, needed to be explicit to actually destroy the data).
Verified after: zero Vault-related resources remain on either cluster, all 9
services still `Healthy` on both, completely unaffected by the removal.

## Known follow-ups (not done here)

- The `vault:` block itself is still present (just `enabled: false`) in
  every `apps/<service>/values.yaml`, on both branches — a deliberate choice
  to keep an easy one-line rollback path. Delete the blocks outright whenever
  you're fully confident Vault won't be needed again.
- No `prod` environment/branch exists yet for either Infisical or this app in
  general — when one does, follow the same pattern: a `prod` Infisical
  environment slug (secrets need populating there first), a third
  `targetRevision` on the Application manifests, and the same
  role-first/environment-gated S3 credential logic already covers `prod`
  automatically (no code change needed, just Helm values).
