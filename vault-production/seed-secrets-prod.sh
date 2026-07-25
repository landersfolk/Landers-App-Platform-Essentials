#!/usr/bin/env bash
# Seeds REAL secrets for one service into Vault, for a given environment.
#
# Unlike vault-seed-secrets.sh (dev), this script does NOT hardcode any secret values —
# there is no such thing as a safe placeholder for a database password or Keycloak
# client secret. Every value below is read from an environment variable that YOU set
# immediately before running this, from wherever your real secrets actually live (a
# password manager, AWS Secrets Manager, your CI/CD's own secret store, etc.) — never
# from a file committed to this repo.
#
# Normally invoked via deploy/05-seed-vault-secrets.sh, which loops this over all 9
# services in one shot instead of running it by hand per service.
#
# Usage (per service — repeat for each of the 9 services):
#   export VAULT_ADDR="https://vault.landers.com:8200"
#   export VAULT_TOKEN="..."          # a token with write access (root, or an admin AppRole)
#   export ENVIRONMENT="prod"         # or "qa" — which Vault path/Spring profile this targets
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
: "${ENVIRONMENT:?Set ENVIRONMENT to qa, prod, etc. — must match the Spring profile the target service will run under}"
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

echo "Writing secret/landers-app/${SERVICE_NAME}/${ENVIRONMENT} ..."
vault kv put "secret/landers-app/${SERVICE_NAME}/${ENVIRONMENT}" "${PATH_ARGS[@]}"
echo "Done. Verify (values redacted by Vault's own kv get -field listing, not shown here):"
vault kv get -format=json "secret/landers-app/${SERVICE_NAME}/${ENVIRONMENT}" | python3 -c "import sys,json; print(list(json.load(sys.stdin)['data']['data'].keys()))"
