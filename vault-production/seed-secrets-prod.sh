#!/usr/bin/env bash
# Seeds REAL production secrets into the production Vault, one service at a time.
#
# Unlike vault-seed-secrets.sh (dev), this script does NOT hardcode any secret values —
# there is no such thing as a safe placeholder for a production database password or
# Keycloak client secret. Every value below is read from an environment variable that
# YOU set immediately before running this, from wherever your real production secrets
# actually live (a password manager, AWS Secrets Manager, your CI/CD's own secret store,
# etc.) — never from a file committed to this repo.
#
# Usage (per service — repeat for each of the 9 services):
#   export VAULT_ADDR="https://vault.landers.com:8200"
#   export VAULT_TOKEN="..."          # a token with write access (root, or an admin AppRole)
#   export SERVICE_NAME="admin-service"
#   export KEYCLOAK_CLIENT_SECRET="..."
#   export KEYCLOAK_ADMIN_CLIENT_SECRET="..."
#   export DB_USERNAME="..."
#   export DB_PASSWORD="..."
#   export FLYWAY_USERNAME="..."      # optional, defaults to DB_USERNAME if unset
#   export FLYWAY_PASSWORD="..."      # optional, defaults to DB_PASSWORD if unset
#   export FIREBASE_CREDENTIALS_JSON="..."   # notification-service only, optional
#   ./seed-secrets-prod.sh
set -euo pipefail

: "${VAULT_ADDR:?}"
: "${VAULT_TOKEN:?}"
: "${SERVICE_NAME:?Set SERVICE_NAME to one of the 9 service names, e.g. admin-service}"
: "${KEYCLOAK_CLIENT_SECRET:?}"
: "${KEYCLOAK_ADMIN_CLIENT_SECRET:?}"
: "${DB_USERNAME:?}"
: "${DB_PASSWORD:?}"

FLYWAY_USERNAME="${FLYWAY_USERNAME:-$DB_USERNAME}"
FLYWAY_PASSWORD="${FLYWAY_PASSWORD:-$DB_PASSWORD}"

PATH_ARGS=(
  "keycloak.clientId=landers-app"
  "keycloak.clientSecret=${KEYCLOAK_CLIENT_SECRET}"
  "keycloak.adminClientId=landers-app-service-account"
  "keycloak.adminClientSecret=${KEYCLOAK_ADMIN_CLIENT_SECRET}"
  "spring.datasource.username=${DB_USERNAME}"
  "spring.datasource.password=${DB_PASSWORD}"
  "spring.flyway.user=${FLYWAY_USERNAME}"
  "spring.flyway.password=${FLYWAY_PASSWORD}"
)

if [ "$SERVICE_NAME" = "notification-service" ]; then
  PATH_ARGS+=("firebase.credentialsJson=${FIREBASE_CREDENTIALS_JSON:-}")
fi

echo "Writing secret/landers-app/${SERVICE_NAME}/qa ..."
vault kv put "secret/landers-app/${SERVICE_NAME}/qa" "${PATH_ARGS[@]}"
echo "Done. Verify (values redacted by Vault's own kv get -field listing, not shown here):"
vault kv get -format=json "secret/landers-app/${SERVICE_NAME}/qa" | python3 -c "import sys,json; print(list(json.load(sys.stdin)['data']['data'].keys()))"
