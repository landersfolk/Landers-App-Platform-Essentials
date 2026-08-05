#!/usr/bin/env bash
# Part 5.6 of EC2_QA_Environment_Setup_Guide.txt, done once instead of 9 times:
# the Keycloak client secrets and DB credentials are shared across all 9 services
# (one realm/client pair, one RDS app database/user), so this prompts for each
# value ONCE and loops vault-production/seed-secrets-prod.sh over every service.
#
# Run this AFTER 04-setup-keycloak.sh (needs its printed client secrets) and
# AFTER creating the app DB user on RDS (Part 9.2 — see 08-configure-configmaps.sh).
#
# Usage: ./05-seed-vault-secrets.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"

VAULT_DIR="${HOME}/landers-app/vault-production"
[ -f "${VAULT_DIR}/seed-secrets-prod.sh" ] || die "Expected ${VAULT_DIR}/seed-secrets-prod.sh to exist (run 02-clone-repos.sh first)."

read -r -p "Vault admin/root token: " -s VAULT_TOKEN_INPUT; echo
read -r -p "KEYCLOAK_CLIENT_SECRET (landers-app, from 04-setup-keycloak.sh output): " -s KC_CLIENT_SECRET; echo
read -r -p "KEYCLOAK_ADMIN_CLIENT_SECRET (landers-app-service-account): " -s KC_ADMIN_CLIENT_SECRET; echo
read -r -p "DB_USERNAME (lander-app_user): " DB_USER
read -r -p "DB_PASSWORD: " -s DB_PASS; echo
read -r -p "FLYWAY_USERNAME [default: same as DB_USERNAME]: " FLYWAY_USER
read -r -p "FLYWAY_PASSWORD [default: same as DB_PASSWORD]: " -s FLYWAY_PASS; echo
read -r -p "FIREBASE_CREDENTIALS_JSON path (blank to skip, notification-service only): " FIREBASE_JSON_PATH

FIREBASE_JSON=""
if [ -n "$FIREBASE_JSON_PATH" ]; then
  [ -f "$FIREBASE_JSON_PATH" ] || die "No file at ${FIREBASE_JSON_PATH}"
  FIREBASE_JSON=$(cat "$FIREBASE_JSON_PATH")
fi

kubectl port-forward svc/vault-prod 8200:8200 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

for svc in $SERVICES; do
  log "Seeding secret/landers-app/${svc}/${ENVIRONMENT}"
  VAULT_ADDR="http://127.0.0.1:8200" \
  VAULT_TOKEN="$VAULT_TOKEN_INPUT" \
  ENVIRONMENT="$ENVIRONMENT" \
  SERVICE_NAME="$svc" \
  KEYCLOAK_CLIENT_SECRET="$KC_CLIENT_SECRET" \
  KEYCLOAK_ADMIN_CLIENT_SECRET="$KC_ADMIN_CLIENT_SECRET" \
  DB_USERNAME="$DB_USER" \
  DB_PASSWORD="$DB_PASS" \
  FLYWAY_USERNAME="${FLYWAY_USER:-$DB_USER}" \
  FLYWAY_PASSWORD="${FLYWAY_PASS:-$DB_PASS}" \
  FIREBASE_CREDENTIALS_JSON="$FIREBASE_JSON" \
  "${VAULT_DIR}/seed-secrets-prod.sh"
done

log "All 9 services seeded for '${ENVIRONMENT}'."
