#!/usr/bin/env bash
# Part 6 of EC2_QA_Environment_Setup_Guide.txt: create the Keycloak DB on RDS,
# deploy Keycloak (public hostname, internal DB), create its Secret out-of-band,
# and bootstrap the realm + both clients + persona roles via kcadm.sh.
#
# This is the single most fiddly manual part of the original guide (three failed
# iterations before landing on the "public KC_HOSTNAME, internal service calls"
# split documented in keycloack-deployment.yaml) — this script reproduces the
# FINAL, correct version directly, no need to rediscover it.
#
# Usage: ./04-setup-keycloak.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"
require_vars RDS_ENDPOINT RDS_ADMIN_USER KEYCLOAK_SUBDOMAIN DOMAIN_ROOT KEYCLOAK_REALM

KEYCLOAK_HOSTNAME_URL="https://${KEYCLOAK_SUBDOMAIN}.${DOMAIN_ROOT}"
DEPLOY_FILE="${HOME}/landers-app/landers-app-deployments/keycloack-deployment.yaml"
[ -f "$DEPLOY_FILE" ] || die "Expected ${DEPLOY_FILE} to exist (run 02-clone-repos.sh first)."

log "Keycloak will be public at ${KEYCLOAK_HOSTNAME_URL} (gateway-service's actual"
log "network calls stay internal — see the deployment file's header comment for why)."

read -r -p "RDS admin (${RDS_ADMIN_USER}) password: " -s RDS_ADMIN_PASSWORD; echo
KC_DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
KC_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

log "Creating 'keycloak' database + user on RDS (idempotent — ignores 'already exists')"
psql "host=${RDS_ENDPOINT} port=5432 dbname=postgres user=${RDS_ADMIN_USER} password=${RDS_ADMIN_PASSWORD} sslmode=require" \
  -v ON_ERROR_STOP=0 \
  -c "CREATE DATABASE keycloak;" \
  -c "CREATE USER keycloak WITH PASSWORD '${KC_DB_PASSWORD}';" \
  -c "ALTER USER keycloak WITH PASSWORD '${KC_DB_PASSWORD}';" \
  -c "GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;"

log "Granting schema-level access (required on PG15+, see the guide's Part 6.1 note)"
psql "host=${RDS_ENDPOINT} port=5432 dbname=keycloak user=${RDS_ADMIN_USER} password=${RDS_ADMIN_PASSWORD} sslmode=require" \
  -c "GRANT ALL ON SCHEMA public TO keycloak;"

RENDERED="/tmp/keycloack-deployment.${ENVIRONMENT}.yaml"
log "Rendering keycloack-deployment.yaml for ${ENVIRONMENT}"
sed -e "s|__RDS_ENDPOINT__|${RDS_ENDPOINT}|g" -e "s|__KEYCLOAK_HOSTNAME_URL__|${KEYCLOAK_HOSTNAME_URL}|g" \
  "$DEPLOY_FILE" > "$RENDERED"
kubectl apply -f "$RENDERED"

if ! kubectl get secret keycloak-secret &>/dev/null; then
  log "Creating keycloak-secret (out-of-band, per the file's own warning — never via kubectl apply)"
  kubectl create secret generic keycloak-secret --namespace default \
    --from-literal=KEYCLOAK_ADMIN=admin \
    --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
    --from-literal=KC_DB_PASSWORD="$KC_DB_PASSWORD"
  warn "Keycloak admin console credentials — save these now, shown only once:"
  warn "  user: admin"
  warn "  password: ${KC_ADMIN_PASSWORD}"
else
  log "keycloak-secret already exists — leaving it alone (do not overwrite a live env's DB password)."
fi

kubectl rollout restart deployment/keycloak
log "Waiting for Keycloak to be ready (this can take ~60-90s)"
kubectl rollout status deployment/keycloak --timeout=180s

KC_ADMIN_PW_FOR_KCADM=$(kubectl get secret keycloak-secret -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)

kcadm() { kubectl exec -it deploy/keycloak -- /opt/keycloak/bin/kcadm.sh "$@"; }

log "Authenticating kcadm.sh"
kcadm config credentials --server http://localhost:8080 --realm master --user admin --password "$KC_ADMIN_PW_FOR_KCADM"

if ! kcadm get realms/"${KEYCLOAK_REALM}" &>/dev/null; then
  log "Creating realm ${KEYCLOAK_REALM}"
  kcadm create realms -s realm="${KEYCLOAK_REALM}" -s enabled=true
else
  log "Realm ${KEYCLOAK_REALM} already exists, skipping"
fi

create_client_if_missing() {
  local client_id="$1"; shift
  local existing
  existing=$(kcadm get clients -r "${KEYCLOAK_REALM}" -q clientId="${client_id}" --fields id --format csv --noquotes | tail -1)
  if [ -z "$existing" ]; then
    log "Creating client ${client_id}"
    kcadm create clients -r "${KEYCLOAK_REALM}" -s clientId="${client_id}" "$@"
  else
    log "Client ${client_id} already exists, skipping"
  fi
}

create_client_if_missing landers-app \
  -s enabled=true -s publicClient=false -s directAccessGrantsEnabled=true \
  -s standardFlowEnabled=false -s serviceAccountsEnabled=false

create_client_if_missing landers-app-service-account \
  -s enabled=true -s publicClient=false -s serviceAccountsEnabled=true \
  -s directAccessGrantsEnabled=false -s standardFlowEnabled=false

log "Granting realm-management roles to the service-account client"
kubectl exec -it deploy/keycloak -- sh -c "
  /opt/keycloak/bin/kcadm.sh add-roles -r ${KEYCLOAK_REALM} \
    --uusername service-account-landers-app-service-account \
    --cclientid realm-management \
    --rolename manage-users --rolename manage-clients" || warn "Role grant failed or already present — verify manually if this is a fresh realm."

log "Creating persona client roles on landers-app"
LOGIN_CLIENT_ID=$(kcadm get clients -r "${KEYCLOAK_REALM}" -q clientId=landers-app --fields id --format csv --noquotes | tail -1)
for role in ADMIN LANDLORD REQUESTER CORPORATE; do
  kcadm create clients/"${LOGIN_CLIENT_ID}"/roles -r "${KEYCLOAK_REALM}" -s name="${role}" 2>/dev/null || warn "Role ${role} may already exist"
done

log "Fetching client secrets (needed for 05-seed-vault-secrets.sh)"
LOGIN_SECRET=$(kubectl exec -it deploy/keycloak -- sh -c "
  ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r ${KEYCLOAK_REALM} -q clientId=landers-app --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh get clients/\$ID/client-secret -r ${KEYCLOAK_REALM}" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
ADMIN_SECRET=$(kubectl exec -it deploy/keycloak -- sh -c "
  ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r ${KEYCLOAK_REALM} -q clientId=landers-app-service-account --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh get clients/\$ID/client-secret -r ${KEYCLOAK_REALM}" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

echo
warn "=== SAVE THESE — needed by 05-seed-vault-secrets.sh, shown only once ==="
warn "KEYCLOAK_CLIENT_SECRET (landers-app):               ${LOGIN_SECRET}"
warn "KEYCLOAK_ADMIN_CLIENT_SECRET (landers-app-service-account): ${ADMIN_SECRET}"
echo

log "Keycloak setup for '${ENVIRONMENT}' complete: ${KEYCLOAK_HOSTNAME_URL}"
warn "Remaining manual step (AWS Console, same pattern as QA Part 6.3): ALB target"
warn "group + listener rule + Route53 record for ${KEYCLOAK_SUBDOMAIN}.${DOMAIN_ROOT} -> port 8180."
