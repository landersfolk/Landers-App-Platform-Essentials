# Vault PRODUCTION server configuration.
#
# This is a separate, independent config from the local k3d dev Vault used by
# dev-setup-fixed.sh / vault-seed-secrets.sh / vault-config.hcl (dev mode: in-memory
# storage, no TLS, hardcoded "root" token — fine for local dev, never for production).
# Nothing here touches or replaces that dev setup.
#
# Real persistent storage (Raft integrated storage, replicated across pods/nodes instead
# of the dev server's in-memory store that's wiped on every restart), TLS termination at
# Vault itself (HashiCorp's own recommendation — don't terminate TLS at a proxy in front
# of Vault), and AWS KMS auto-unseal (no manual `vault operator unseal` with Shamir key
# shares after every restart/reschedule — the KMS key unseals it automatically on boot).
#
# Deploy via vault-statefulset.yaml (Kubernetes) — see that file's header comment for the
# full first-time bootstrap sequence (init, AppRole setup, secret migration).

ui = true

# TLS deliberately disabled for the QA deployment: this Vault is never reachable
# outside the k3s pod network (no LoadBalancer Service, no ALB route to it — only
# other pods in this cluster talk to it over plain HTTP on the ClusterIP Service).
# Re-enable tls_cert_file/tls_key_file (see git history / vault-production/README.md)
# if this pattern is ever promoted to a real internet-facing production Vault.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Raft integrated storage — replicated across however many pods this StatefulSet runs
# (start at 1 replica to get real persistence immediately; bump to 3 for HA/quorum once
# you're ready — see the README for the retry_join pattern needed at 3 replicas).
storage "raft" {
  path    = "/vault/data"
  node_id = "${HOSTNAME}"
}

# AWS KMS auto-unseal. Key created 2026-07-23 (alias landers-qa-vault-unseal), region
# eu-west-1. Access is granted via landers-ec2-s3-role's inline "vault-kms-unseal" policy
# on the EC2 instance profile — NOT a static AWS access key (this pod picks up credentials
# automatically from the instance metadata service via that role).
seal "awskms" {
  region     = "eu-west-1"
  kms_key_id = "ee8ceade-aa4b-4e1a-8290-73732dcc5851"
}

# Internal-only — this Vault has no public DNS name (see the TLS note above), only
# in-cluster pods reach it, via the vault-prod ClusterIP Service.
api_addr     = "http://vault-prod:8200"
cluster_addr = "http://${HOSTNAME}.vault-prod-internal:8201"

# Keep memory locked (no swap) so secret material never touches disk swap space.
# Requires IPC_LOCK capability on the container, same as the existing dev Deployment already has.
disable_mlock = false

# Vault logs audit-relevant request metadata (not secret values) to stdout by default from
# the `file` audit device below — enabled post-init via `vault audit enable file
# file_path=/vault/logs/audit.log` (see README); not configurable from this server stanza.
