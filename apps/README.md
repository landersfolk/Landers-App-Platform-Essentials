# apps/

One `values.yaml` per deployable service, consumed by `charts/landers-app` (the
one shared Helm chart) via the matching `argocd/applications/<service>.yaml`.

Each service's own GitHub Actions workflow (`.github/workflows/ci.yml` in that
service's repo) updates `image.tag` here on every push to `main`, commits, and
pushes — ArgoCD picks up the change and syncs it to the cluster automatically.
Nothing else in this directory should need manual edits day-to-day.

To add a new service: copy an existing `apps/<service>/values.yaml`, adjust
`nameOverride` / `image.repository` / port / `vault.secretName`, then add a
matching file in `argocd/applications/`.
