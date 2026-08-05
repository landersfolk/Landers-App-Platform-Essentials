# Jenkins/JFrog → GitHub Actions/ArgoCD migration (2026-08-05)

**Status: COMPLETE and fully verified.** `main` is merged and pushed in all
15 repos. ArgoCD's `argocd/root-app.yaml` is applied on the `k3d-landers-app`
cluster, the old JFrog Artifactory pod/svc/pvc is deleted. **All 9 backend
services + both frontends are confirmed `Healthy`/`Running`** in the cluster
— every single ArgoCD Application shows `Synced`/`Healthy`, every pod is
`1/1 Running`. `quality` (the live EC2 QA branch) was deliberately never
touched by any of this — every fix below only reads from it, never
pushes/merges into it.

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

- Single environment only (`qa` `SPRING_PROFILES_ACTIVE` baked into each
  `apps/<service>/values.yaml`). For a real prod environment, either add a
  second `apps/<service>/values-prod.yaml` + a second ArgoCD Application per
  service, or parameterize further — kept out of scope to avoid over-building
  before there's a second real environment to point it at.
- Frontend `Service`s are plain `ClusterIP`-shaped (matches the existing
  backend pattern) — the old `deploy/10-deploy-frontend.sh`'s
  `LoadBalancer`-on-a-host-port + ALB target group wiring for
  lander-web/admin-dashboard isn't reproduced in the chart; add it if the new
  pipeline needs to fully replace that script's job.
- `data-module`'s remote moved from `landers-app/data-module` to
  `landersfolk/data-module` (GitHub told us on push) — the pom.xml/workflow
  changes here already target the new `landersfolk` URL, but the local clone's
  `git remote` still points at the old one; update it when convenient
  (`git remote set-url origin git@github.com:landersfolk/data-module.git`).
- `Jenkins-Shared-Library` repo and the top-level `Jenkinsfile` (on this repo's
  `quality` branch) are now unused but weren't deleted — nothing references
  them anymore, safe to archive once confirmed.
