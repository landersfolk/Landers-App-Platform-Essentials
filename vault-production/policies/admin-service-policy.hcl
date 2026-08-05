# Least-privilege policy for admin-service: read-only access to its OWN secret path only,
# any environment profile (qa/prod/etc - same policy works everywhere, matching this
# repo's env-var-driven Vault config convention, see qa_backend_deploy_2026_07_24 memory).
# Nothing here can read another service's secrets, list unrelated paths, or write/delete
# anything - a compromised service can leak only its own credentials, not the whole vault.

path "secret/data/landers-app/admin-service/*" {
  capabilities = ["read"]
}

path "secret/metadata/landers-app/admin-service/*" {
  capabilities = ["read", "list"]
}
