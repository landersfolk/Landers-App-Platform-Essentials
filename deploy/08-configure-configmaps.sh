#!/usr/bin/env bash
# Part 9 of EC2_QA_Environment_Setup_Guide.txt: create the app DB + users on RDS,
# point every service's `prod`-profile datasource/flyway URL at this environment's
# RDS endpoint (mirrors exactly what QA needed for ITS `qa` profile — the `prod`
# profile block in every configmap still has the original in-cluster
# postgres-db:5432 placeholder, untouched since these files were scaffolded), and
# fix gateway-service's prod issuer-uri to the public Keycloak hostname (Part 9.3's
# classic silent-401 trap if missed).
#
# NOTE: this edits the checked-in configmap YAML files in Platform-Essentials (not
# just a live-cluster patch) — commit + push the result so it's not re-clobbered by
# a later unrelated `git pull` + apply. Safe to re-run (idempotent replace).
#
# Usage: ./08-configure-configmaps.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"
require_vars RDS_ENDPOINT RDS_APP_DB_NAME RDS_ADMIN_USER KEYCLOAK_SUBDOMAIN DOMAIN_ROOT

if [ "$ENVIRONMENT" = "qa" ]; then
  die "This script targets the 'prod'-labeled profile block in each configmap — QA's 'qa' profile was already configured by hand per the original guide. Refusing to run for ENVIRONMENT=qa to avoid confusion; if you specifically need to redo QA's RDS wiring, edit the qa profile block manually as the guide's Part 9.1 describes."
fi

CONFIGMAP_DIR="${HOME}/landers-app/landers-app-config-maps/postgres"
[ -d "$CONFIGMAP_DIR" ] || die "Expected ${CONFIGMAP_DIR} to exist (run 02-clone-repos.sh first)."

read -r -p "RDS admin (${RDS_ADMIN_USER}) password: " -s RDS_ADMIN_PASSWORD; echo
APP_DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
FLYWAY_DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

log "Creating app database + users on RDS (idempotent — ignores 'already exists')"
psql "host=${RDS_ENDPOINT} port=5432 dbname=postgres user=${RDS_ADMIN_USER} password=${RDS_ADMIN_PASSWORD} sslmode=require" \
  -v ON_ERROR_STOP=0 \
  -c "CREATE DATABASE \"${RDS_APP_DB_NAME}\";" \
  -c "CREATE USER \"lander-app_user\" WITH PASSWORD '${APP_DB_PASSWORD}';" \
  -c "ALTER USER \"lander-app_user\" WITH PASSWORD '${APP_DB_PASSWORD}';" \
  -c "CREATE USER \"flyway-migration\" WITH PASSWORD '${FLYWAY_DB_PASSWORD}';" \
  -c "ALTER USER \"flyway-migration\" WITH PASSWORD '${FLYWAY_DB_PASSWORD}';"

log "Granting schema-level access + enabling PostGIS (required on PG15+, see Part 9.2)"
psql "host=${RDS_ENDPOINT} port=5432 dbname=${RDS_APP_DB_NAME} user=${RDS_ADMIN_USER} password=${RDS_ADMIN_PASSWORD} sslmode=require" \
  -c "GRANT ALL ON SCHEMA public TO \"lander-app_user\";" \
  -c "GRANT ALL ON SCHEMA public TO \"flyway-migration\";" \
  -c "CREATE EXTENSION IF NOT EXISTS postgis;"

echo
warn "=== SAVE THESE — needed by 05-seed-vault-secrets.sh (DB_USERNAME/DB_PASSWORD/FLYWAY_*) ==="
warn "DB_USERNAME=lander-app_user   DB_PASSWORD=${APP_DB_PASSWORD}"
warn "FLYWAY_USERNAME=flyway-migration   FLYWAY_PASSWORD=${FLYWAY_DB_PASSWORD}"
echo

log "Rewriting each configmap's prod-profile datasource/flyway URL to point at ${RDS_ENDPOINT}"
python3 - "$CONFIGMAP_DIR" "$RDS_ENDPOINT" <<'PYEOF'
import re, sys, pathlib

configmap_dir, rds_endpoint = sys.argv[1], sys.argv[2]
url_pattern = re.compile(
    r'jdbc:postgresql://postgres-db(?:-prod)?:5432/landers-app-lander-db'
)
replacement = f'jdbc:postgresql://{rds_endpoint}:5432/landers-app-lander-db?sslmode=require'

for path in sorted(pathlib.Path(configmap_dir).glob('*-configmap.yaml')):
    text = path.read_text()
    marker = '# PROD Profile'
    idx = text.find(marker)
    if idx == -1:
        continue  # gateway-service has no datasource block at all
    head, tail = text[:idx], text[idx:]
    new_tail, n = url_pattern.subn(replacement, tail)
    if n:
        path.write_text(head + new_tail)
        print(f'  {path.name}: replaced {n} URL(s)')
PYEOF

GATEWAY_CM="${CONFIGMAP_DIR}/gateway-service-configmap.yaml"
if [ -f "$GATEWAY_CM" ]; then
  log "Fixing gateway-service's prod issuer-uri to the public Keycloak hostname (Part 9.3)"
  python3 - "$GATEWAY_CM" "$KEYCLOAK_SUBDOMAIN" "$DOMAIN_ROOT" <<'PYEOF'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
keycloak_subdomain, domain_root = sys.argv[2], sys.argv[3]
public_issuer = f'https://{keycloak_subdomain}.{domain_root}/realms/landers-realm'

text = path.read_text()
marker = '# --- 4. PROD PROFILE ---'
idx = text.find(marker)
if idx == -1:
    print('  WARNING: could not find PROD PROFILE marker in gateway-service-configmap.yaml — fix issuer-uri manually')
else:
    head, tail = text[:idx], text[idx:]
    tail, n = re.subn(r'issuer-uri: http://keycloak:8180/realms/landers-realm', f'issuer-uri: {public_issuer}', tail, count=1)
    if n:
        path.write_text(head + tail)
        print(f'  gateway-service-configmap.yaml: issuer-uri -> {public_issuer}')
    else:
        print('  WARNING: issuer-uri line not found/already changed — verify manually')
PYEOF
fi

log "Applying all configmaps"
kubectl apply -f "$CONFIGMAP_DIR/"

warn "Commit + push these configmap changes in Platform-Essentials now, so a future"
warn "'git pull' + re-apply on this box doesn't look like it reverted anything."
log "Configmaps configured for '${ENVIRONMENT}'."
