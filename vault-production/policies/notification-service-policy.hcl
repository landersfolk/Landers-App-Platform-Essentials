# Least-privilege policy for notification-service: read-only access to its OWN secret path only.
# Nothing here can read another service's secrets, list unrelated paths, or write/delete
# anything — a compromised service can leak only its own credentials, not the whole vault.

path "secret/data/landers-app/notification-service/prod" {
  capabilities = ["read"]
}

path "secret/metadata/landers-app/notification-service/prod" {
  capabilities = ["read", "list"]
}
