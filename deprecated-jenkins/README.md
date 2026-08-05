# Deprecated: Jenkins

This directory is kept only so the Jenkins-era manifests aren't lost. Jenkins was
replaced 2026-08-05 by GitHub Actions (CI) + ArgoCD (CD) — see `../MIGRATION_GUIDE.md`.

Nothing in the pipeline applies these manifests anymore. If a live cluster still
has the Jenkins Deployment running from before the migration, remove it by hand:

```
kubectl delete deployment/jenkins service/jenkins -n <jenkins-namespace>
```

The `Jenkins-Shared-Library` repo (landersfolk/Jenkins-Shared-Library) and the
top-level `Jenkinsfile` that used to live in this repo's `quality` branch are
likewise unused now — safe to archive once you've confirmed nothing still
references them.
