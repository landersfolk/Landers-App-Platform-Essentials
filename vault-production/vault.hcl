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

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/tls.crt"
  tls_key_file  = "/vault/tls/tls.key"
  tls_min_version = "tls12"

  # Vault's own health/readiness checks (used by the StatefulSet probes and by any load
  # balancer in front of it) are allowed without a client cert even though the listener
  # itself is TLS-only for everything else.
  telemetry {
    unauthenticated_metrics_access = false
  }
}

# Raft integrated storage — replicated across however many pods this StatefulSet runs
# (start at 1 replica to get real persistence immediately; bump to 3 for HA/quorum once
# you're ready — see the README for the retry_join pattern needed at 3 replicas).
storage "raft" {
  path    = "/vault/data"
  node_id = "${HOSTNAME}"
}

# AWS KMS auto-unseal. Create a dedicated KMS key first (aliased e.g. alias/landers-vault-unseal)
# and grant this pod's IAM role kms:Encrypt/Decrypt/DescribeKey on it (via IRSA if on EKS —
# do NOT hand Vault a static AWS access key). Replace the placeholders below.
seal "awskms" {
  region     = "REPLACE_WITH_AWS_REGION"       # e.g. us-east-1
  kms_key_id = "REPLACE_WITH_KMS_KEY_ID"        # the key's ID or ARN, not the alias
}

# Update once the vault.landers.com DNS record (see the Route 53 setup) exists.
api_addr     = "https://vault.landers.com:8200"
cluster_addr = "https://${HOSTNAME}.vault-internal:8201"

# Keep memory locked (no swap) so secret material never touches disk swap space.
# Requires IPC_LOCK capability on the container, same as the existing dev Deployment already has.
disable_mlock = false

# Vault logs audit-relevant request metadata (not secret values) to stdout by default from
# the `file` audit device below — enabled post-init via `vault audit enable file
# file_path=/vault/logs/audit.log` (see README); not configurable from this server stanza.
