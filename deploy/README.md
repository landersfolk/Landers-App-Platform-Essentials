# Multi-environment deploy scripts

Turns `EC2_QA_Environment_Setup_Guide.txt` (1,100+ lines, originally followed by
hand for QA, one command at a time) into parameterized, mostly-idempotent
scripts. Standing up a new environment — prod, or any future one — is now:
copy an env file, fill in a handful of real values, run the scripts in order.

**Scope**: this covers everything that runs *on or via* the EC2 box — OS setup,
Docker, k3s, Vault, Keycloak, Kafka/Redis/Artifactory, builds, and the 9
services + 2 frontends. It deliberately does **not** cover AWS-side
provisioning (VPC, ALB, RDS instance creation, KMS key, IAM roles, Route53,
ACM) — those stay one-time manual AWS Console actions, exactly as they were
for QA (see `VPC_Setup_Guide.txt` and the guide's Part 0). Each script prints
a `warn` line naming the specific manual AWS step it depends on, where
relevant.

## Model: one full stack per environment

Confirmed approach: production is a **second, fully independent EC2 box** —
its own k3s cluster, its own Vault, its own Keycloak realm/secrets, its own
Jenkins instance, its own RDS instance. Nothing is shared with QA except the
git repos and this scripts directory. This mirrors exactly how QA was built,
which is what "just some configs" means in practice: same sequence of
operations, different values plugged in (domain, RDS endpoint, KMS key,
Keycloak secrets — see `envs/prod.env.example`).

## First time for a new environment (e.g. prod)

```bash
cp envs/prod.env.example envs/prod.env
# edit envs/prod.env — fill in KMS_KEY_ID, RDS_ENDPOINT, subdomain scheme
```

Then, **on the target EC2 box** (not your laptop):

```bash
./deploy-all.sh prod
```

This walks through 01 → 10 in order, pausing before steps that need a value
only you have (RDS admin password, Keycloak secrets, a KMS key that must
already exist in AWS Console). Run `./smoke-test.sh prod` at the end.

If you'd rather run steps one at a time (recommended the first time, so you
can inspect each stage before moving on):

| Script | Guide part | What it does |
|---|---|---|
| `01-bootstrap-host.sh` | 1.2-1.4, 2-4 | OS prep, Docker + local registry, Node, k3s |
| `02-clone-repos.sh` | 1.5 | Clone all 14 repos, symlink shared infra dirs |
| `03-deploy-vault.sh` | 5.3-5.5 | Deploy Vault (KMS auto-unseal), init, AppRole bootstrap |
| `04-setup-keycloak.sh` | 6 | RDS `keycloak` DB, deploy, realm + both clients + persona roles |
| `08-configure-configmaps.sh` | 9 | RDS app DB/users, point `prod` profile at RDS, fix gateway issuer-uri |
| `05-seed-vault-secrets.sh` | 5.6 | Seed all 9 services' Vault secrets in one pass (was 9 manual runs) |
| `06-core-infra.sh` | 7 | Kafka/Kafdrop, Redis, Artifactory |
| `07-build-commons.sh` | 8 | `mvn deploy` commons-module + data-module |
| `09-deploy-services.sh` | 10-11 | Build+push+deploy all 9 services, in dependency order |
| `10-deploy-frontend.sh` | 12 | Build+push+deploy website + admin-dashboard |
| `smoke-test.sh` | 14 | Automated version of the smoke-test checklist |

Run `08-configure-configmaps.sh` before `05-seed-vault-secrets.sh` — the
latter needs the DB credentials the former generates, plus the Keycloak
secrets `04-setup-keycloak.sh` printed.

## Day-2: redeploying one service after a code change

Dockerfiles are now runtime-only (they just copy a pre-built `target/*.jar`
in, no Maven inside the Docker build — see each service's Dockerfile), so
the jar has to be built first:
```bash
cd <service> && mvn -B clean package -DskipTests && docker build --network=host -t localhost:5000/<service>:<env> . && docker push localhost:5000/<service>:<env> && kubectl rollout restart deployment/<service>
```
Or via Jenkins — see below.

## Jenkins

Each environment's Jenkins instance builds/deploys ONLY that environment,
driven by one env var (`DEPLOY_ENV`, set in `jenkins/jenkins-deployment.yaml`,
default `qa`). No Jenkinsfile in any of the 9 service repos needs to change
between environments — `microservicePipeline(service: 'x')` is identical on
every branch. The 2 frontend repos have one intentional exception: the
Angular `--configuration` flag (`buildConfig` param) is passed explicitly per
call site, since Landers-Web-Site has no `qa` build configuration at all (see
`10-deploy-frontend.sh`'s header note) — set it per-branch in each repo's
Jenkinsfile.

To stand up prod's own Jenkins: apply `jenkins/jenkins-deployment.yaml` on the
prod box with `DEPLOY_ENV: "prod"`, same as `06-core-infra.sh`'s pattern for
everything else.

## What's still manual (by design)

- Creating the KMS key + granting it to the instance role (AWS Console, Part
  5.1/5.2) — one-time per environment.
- ALB target groups, listener rules, Route53 records, ACM cert coverage for
  each new subdomain (Part 6.3 / 11.2 / 12.4) — flagged inline by the scripts
  above at the point each hostname comes into existence.
- Deciding prod's actual subdomain scheme (`envs/prod.env.example` defaults to
  dropping the `qa-`/`-qa` prefixes — not yet confirmed as of this being
  written, see the original guide's Part 6 naming note).
- `vault operator init`'s recovery keys + root token, and Keycloak/RDS admin
  passwords — these are prompted for interactively and never written to disk
  by any script here, by design.

## Files touched to make this environment-agnostic

These were previously QA-hardcoded; now they're generic templates rendered
per-environment by the scripts above — don't `kubectl apply` them directly:
- `vault-production/vault-statefulset.yaml`, `vault-production/vault.hcl` (KMS region/key)
- `vault-production/seed-secrets-prod.sh` (was hardcoded to write only `.../qa`)
- `landers-app-deployments/keycloack-deployment.yaml` (RDS endpoint, public hostname)
- `landers-app-deployments/*-service-deployment.yaml` (image tag, `SPRING_PROFILES_ACTIVE`)
