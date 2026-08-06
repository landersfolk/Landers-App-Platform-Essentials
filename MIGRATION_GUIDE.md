# Jenkins/JFrog → GitHub Actions/ArgoCD migration (2026-08-05)

**Status: COMPLETE on BOTH clusters.** `main` (dev, k3d-landers-app) and
`quality` (QA, the real EC2 box `i-0285595f45e8d9f7d`, private subnet, cluster
name `landers-qa`) are both fully live — all 9 backend services + both
frontends confirmed `1/1 Running` on each. `quality` was merged from `main`
only after the user explicitly asked for it (see "QA EC2 rollout" below);
before that, every fix only ever read from `quality`, never pushed to it.

## QA EC2 rollout (same day, after dev cluster verified)

Once the k3d/dev cluster was fully working, the user asked to do the same on
the real QA EC2 server, which pulls from `quality` — plus "consider using
Vault like production" (real AppRole, not the dev cluster's shared TOKEN).

**What's different about this cluster vs k3d, and why:**
- **Vault**: `quality`'s Vault (`vault-prod-0`, real HA/raft/awskms-auto-unseal
  StatefulSet) already had AppRole fully bootstrapped — real
  `<service>-vault-creds` k8s Secrets already existed (12+ days old, from
  `vault-production/setup-approle.sh`). `apps/<service>/values.yaml` on
  `quality` uses `authMethod: APPROLE` + `host: vault-prod` (not
  `vault-server`/`TOKEN` like the dev cluster).
- **This cluster was already live** — 9 services + 2 frontends already
  running via the OLD Jenkins pipeline (`localhost:5000` images), serving
  real QA traffic, when ArgoCD was installed. **Automated sync was
  deliberately left OFF** for every per-service Application (manual sync
  only) — each one was reviewed with `argocd app diff` before syncing, to
  avoid ArgoCD silently overwriting a live pod with something wrong on first
  contact. This caught two real bugs before they ever touched a live pod:
  1. `service.type` had no default (silently ClusterIP) — would have flipped
     `gateway-service`'s externally-routed `LoadBalancer` Service. Fixed by
     adding `service.type` to the chart + overriding it to `LoadBalancer` for
     `gateway-service`/`admin-dashboard`/`lander-web` specifically (confirmed
     via `kubectl get svc` which services actually need it).
  2. `admin-dashboard`/`lander-web`'s `service.port` was `80`, but their real
     Services use port `4400`/`4300` (`ADMIN_DASHBOARD_PORT`/`WEBSITE_PORT`
     from `deploy/envs/qa.env`) with `targetPort: 80` — a straight `port: 80`
     would have replaced the whole `ports:` array on sync (kubectl apply
     doesn't merge Service port lists), silently changing the NodePort and
     breaking whatever the ALB target group points at. Fixed by setting
     `service.port` to the correct 4400/4300 per service, `containerPort`
     unchanged at 80.
- After both fixes, every diff showed only the expected image swap +
  `imagePullSecrets` addition — synced all 11 one by one, all came up
  `1/1 Running`, and all 3 `LoadBalancer` Services kept their exact same
  external IP/port/NodePort (zero ALB disruption).
- **Jenkins and Artifactory are still running on this box, untouched** —
  user's explicit call to leave them alone until the new pipeline's been
  proven out further. Don't remove them without asking again.
- Each service's `.github/workflows/ci.yml` now triggers on push to `quality`
  too (not just `main`), and the `update-gitops` job checks out
  Platform-Essentials at `ref: github.ref_name` so a `quality` push bumps
  `quality`'s values.yaml, a `main` push bumps `main`'s — same repo, same
  file path, correct branch picked automatically.
- `argocd/applications/*.yaml` + `root-app.yaml` on the `quality` branch have
  `targetRevision: quality` (vs `main` on the dev branch) — each branch's
  ArgoCD instance watches its own revision.

## Resolved: admin-service, landlord-service, corporate-service, Admin-Dashboard-Front-End

These 4 got `quality` merged into `main` by mistake instead of `development`
during the initial bulk migration (a bookkeeping bug — see
[[cicd_migration_jenkins_to_ghactions_argocd_2026_08_05]] in Claude's memory
for the full story), which meant no CI workflow / GitHub Packages pom.xml
ever landed on their `main`. Redone properly (`development` → `main`), which
surfaced real application-code conflicts in all 4 — 7 files in admin-service,
1 in landlord-service, 1 in corporate-service, 16 in Admin-Dashboard-Front-End
(login, dashboard, users/corporates/landlords/requesters pages). Every single
conflict was checked by hand (diffed both sides, not just line counts) and
resolved by keeping `main`'s (i.e. `quality`'s) version — in every case
`development` was strictly behind, never had unique content `main` lacked.
Notably: `main` has the phone-based admin login (`development` still had the
pre-2026-08-01 email login), the AuthService/ToastService-based error
interceptor, and an `untracked()` refetch-loop fix — all real shipped fixes
`development` had simply never received. `environment.ts` in
Admin-Dashboard-Front-End was the one deliberate exception (kept
`development`'s localhost value) since Angular's `production` build config
replaces that file entirely via `fileReplacements` — it's never actually used
in the CI-built artifact either way.

- **Landers-Web-Site**: `main` is branch-protected (PR required) — this one's
  done: the reconciled commit (real pre-existing local/remote divergence +
  the CI workflow) was opened as PR #1 from branch `ci-cd-migration-to-main`
  and merged. `lander-web` is confirmed `Healthy`/`Running`.
- **user-service**: GitHub's default branch is still `feature/user-service-auth`
  (a `main` branch didn't exist before this migration — created it fresh from
  `development`). Cosmetic only; doesn't block the CI trigger. Fix in repo
  settings when convenient.
- **commons-module**: `development`/`main` were also missing a large chunk of
  `quality`'s real work (admin-dashboard DTOs/Feign clients across corporate/
  landlord/requester/payment/booking + Flyway V91-V96) — this one WAS merged
  in cleanly (4 small conflicts, all "development's version was a strict
  subset of quality's", resolved by taking quality's side) since it's a
  shared library, not a specific service's business logic. Already published
  and live — this is what unblocked booking/requester/user-service's builds.

## Post-launch fix: Maven repository id collision (2026-08-05, same day)

First real CI run failed everywhere with `'repositories.repository.id' must
be unique: github`. The original design gave both GitHub Packages
`<repository>` entries (commons-module, data-module) the same id `github`,
assuming Maven only matches credentials by id — true for `settings.xml`
servers, but Maven separately rejects duplicate repository ids within one
pom.xml outright. Fixed by splitting into `github-commons-module` /
`github-data-module`, both still authenticated by the same `PACKAGES_PAT` via
two `<server>` entries. Also stopped relying on `actions/setup-java`'s
single-server templating (it can only emit one `<server>`) — settings.xml is
now written directly in a workflow step. If you're reading pom.xml/workflow
examples below, they already reflect this fix.

## What changed

| Before | After |
|---|---|
| Jenkins (`microservicePipeline`/`angularAppPipeline`/`librarySnapshotPipeline`) | GitHub Actions — one `.github/workflows/ci.yml` (or `publish.yml`) per repo |
| JFrog Artifactory, Maven artifacts only | GitHub Packages Maven registry (`maven.pkg.github.com`) |
| `localhost:5000` (no real registry before) | `ghcr.io/landersfolk/<image-name>` |
| `kubectl apply` from Jenkins / manual `deploy/09-10` scripts | ArgoCD, auto-syncing this repo's `charts/` + `apps/` |
| Keycloak, Vault, Docker, Kubernetes | unchanged |

## New folder structure (this repo)

```
charts/landers-app/        one shared Helm chart (Deployment+Service+optional HPA)
                            used by every backend AND frontend service
apps/<service>/values.yaml one per deployable service — image repo/tag, port,
                            Vault secret name. CI bumps image.tag here on every build.
argocd/applications/*.yaml one ArgoCD Application per service
argocd/root-app.yaml       app-of-apps — apply this ONCE, ArgoCD manages the rest
deprecated-jenkins/        old jenkins/ dir, kept for reference only
```

## Per-repo changes

- **9 Spring Boot services** (gateway/admin/requester/landlord/corporate/user/
  booking/payment/notification-service): `pom.xml` now pulls commons-module +
  data-module from GitHub Packages; new `.github/workflows/ci.yml` (mvn verify
  → docker build/push → bump this repo's `apps/<service>/values.yaml`).
- **commons-module**, **data-module**: `distributionManagement` now points at
  their own GitHub Packages registry; new `.github/workflows/publish.yml`
  (`mvn deploy` on push to main). **data-module's changes are on
  `feature/landlord`, not `development`** — that repo's `development` branch
  is stale (Jan 2026, unrelated multi-module restructure, Spring Boot 4.0.1).
  `feature/landlord` is the branch every service's pom.xml actually matches
  and has the most recent commit — confirm this is still what you want before
  merging anywhere.
- **Admin-Dashboard-Front-End**, **Landers-Web-Site**: new
  `.github/workflows/ci.yml` (npm build → docker build/push → bump values.yaml).
  Both always build the "production" Angular config now (admin-dashboard's old
  "qa" config isn't wired into this workflow — see the workflow's comment).
- **Lander-Folk-Mobile-App**: new `.github/workflows/ci.yml` — Android APK only
  (`gradlew assembleRelease`, signed with the existing debug keystore, attached
  to a GitHub Release). No Docker, no GitOps step. iOS is not built — needs a
  macOS runner + Apple signing secrets, neither of which exist yet.
- **This repo**: `infrastructure.yaml` no longer deploys the in-cluster JFrog
  Artifactory Deployment/PVC. `jenkins/` moved to `deprecated-jenkins/jenkins/`.

## GitHub Actions secrets to add

Org-level (`landersfolk` org → Settings → Secrets and variables → Actions),
so every repo gets them without per-repo setup:

| Secret | Scope | Used by | Purpose |
|---|---|---|---|
| `PACKAGES_PAT` | classic PAT, `read:packages` + `write:packages`, owned by an org member with access to commons-module + data-module | all 9 services (read), commons-module + data-module (read+write) | Maven auth against GitHub Packages — needed because the default `GITHUB_TOKEN` can't read another repo's private packages |
| `GITOPS_PAT` | classic PAT, `repo` scope (or fine-grained `contents:write` on this repo) | all 9 services + 2 Angular apps | push the `image.tag` bump commit to this repo |

Not needed as secrets: `GITHUB_TOKEN` (built-in, used for ghcr.io push and the
mobile GitHub Release — both same-repo operations). ArgoCD's own access to
this repo is already handled by the `landersfolk-argocd` GitHub App (App ID
4494976) — nothing to add for that.

Optional, only if you want real Android release signing instead of the debug
keystore: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (not wired into the workflow yet).

## GitHub Packages: one more manual step

GitHub Packages restricts cross-repo `GITHUB_TOKEN` reads by default, which is
exactly why `PACKAGES_PAT` exists above. If you'd rather avoid a standing PAT
long-term: on each of commons-module and data-module, go to the package's
own Settings → "Manage Actions access" → add every consuming repo. Then the
9 services' workflows could switch from `PACKAGES_PAT` to `GITHUB_TOKEN`. Not
done here — the PAT is simpler and works today.

## Activating this (once you're ready)

1. Review + merge `development` → `main` in each of the 15 repos (in
   dependency order: commons-module, data-module, then the 9 services, then
   the 2 Angular apps; mobile app is independent).
2. Add the two secrets above at the org level.
3. `kubectl apply -f argocd/root-app.yaml` — one time, on the cluster ArgoCD
   itself runs on.
4. Push something small to each service's `main` to trigger the first real
   CI run and confirm the image lands in `ghcr.io/landersfolk/<service>` and
   the ArgoCD Application syncs.

## Accessing the ArgoCD dashboard

ArgoCD's web UI is never exposed publicly on either cluster — reach it via a
local port-forward (dev) or an SSM tunnel (QA), never a public subdomain, so
there's no new attack surface beyond the IAM/kubeconfig access you already
have.

### Dev (k3d-landers-app)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Open `https://localhost:8080`, accept the self-signed cert, log in as `admin`
with the password above.

### QA (EC2 `i-0285595f45e8d9f7d`, private subnet, cluster `landers-qa`)

No direct network path exists into this subnet — SSM brokers the connection
(via AWS's SSM service, not a raw tunnel), so access is gated purely by IAM
(`ssm:StartSession` on this instance), not network reachability. Needs two
terminals.

**Terminal A — SSM into the box, forward ArgoCD's port on the instance itself:**

```bash
aws ssm start-session --region eu-west-1 --target i-0285595f45e8d9f7d
```

Inside that session:

```bash
export HOME=/root
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
nohup kubectl -n argocd port-forward svc/argocd-server 8080:443 > /tmp/argocd-pf.log 2>&1 & disown
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

(`disown` keeps the tunnel alive even if the SSM session's job control hiccups;
use `-n argocd` inline rather than `kubectl config set-context --current
--namespace=argocd` — that flag persists in the real kubeconfig and has
caused confusion before, see the CI/CD migration memory.)

**Terminal B — on your own laptop, tunnel through SSM to that port:**

```bash
aws ssm start-session --region eu-west-1 --target i-0285595f45e8d9f7d --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

(Keep this as one line — pasted `\` line-continuations can pick up trailing
whitespace and break.)

Open `https://localhost:8080`, accept the self-signed cert, log in as `admin`
with the password from Terminal A.

When done: Ctrl+C both terminal sessions, and in Terminal A run
`pkill -f "port-forward svc/argocd-server"` to stop the tunnel on the box
rather than leaving it running.

## Kubernetes cleanup (do this by hand — nothing here touches a live cluster)

Check what's actually still running first:

```
kubectl get pods -A | grep -Ei 'artifactory|jenkins'
```

- **JFrog Artifactory** (`deployment/artifactory`, `svc/jfrog-artifactory`,
  `pvc/artifactory-data`) — no longer applied by `infrastructure.yaml`. If
  still running: `kubectl delete deployment/artifactory svc/jfrog-artifactory
  pvc/artifactory-data`.
- **Jenkins** (`jenkins/jenkins-deployment.yaml`, moved to
  `deprecated-jenkins/`) — nothing applies this anymore either. If still
  running: `kubectl delete deployment/jenkins svc/jenkins` (check the actual
  names/namespace via `kubectl get all -l app=jenkins -A` first — the old
  manifest didn't pin a namespace).
- Local dev: `dev-setup-fixed.sh`'s Artifactory port-forward was removed;
  `landlord-service/.m2/settings.xml` and `CLAUDE.md` were updated to
  reference GitHub Packages instead of Artifactory/`:8082`.
- **Not removed / still needed**: Docker, Kubernetes, Keycloak, Vault, Kafka,
  Redis, Postgres/RDS, the LGTM observability stack — none of this migration
  touches them.

## Known follow-ups (not done here)

- Only one environment per branch is wired (`main` → dev k3d, `quality` → QA
  EC2) — no `prod` yet. When a real prod cluster/branch exists, follow the
  exact same pattern: a third `targetRevision` on the Application manifests,
  `APPROLE` Vault (already the QA pattern, just point at prod's Vault/AppRole
  role IDs once bootstrapped there), and check `kubectl get svc` on that
  cluster for any `LoadBalancer` overrides before the first sync — don't
  assume QA's port-mapping quirks (see "QA EC2 rollout" above) carry over
  unchanged.
- Local dev machine cleanup, low-risk, do whenever convenient:
  - `data-module`'s local git remote still points at the old
    `landers-app/data-module` URL (GitHub auto-redirects, but worth fixing):
    `git remote set-url origin git@github.com:landersfolk/data-module.git`
  - `Jenkins-Shared-Library` repo — nothing references it anymore (QA's
    Jenkins jobs are disabled, Jenkins/Artifactory pods + PVCs are deleted
    from the QA cluster entirely as of 2026-08-05). Archive it via GitHub's
    repo settings when convenient.
  - The top-level `Jenkinsfile` on this repo's `quality` branch
    (`configMapPipeline()`) is inert now — nothing runs it — but wasn't
    removed; low priority, delete whenever.
