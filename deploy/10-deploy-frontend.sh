#!/usr/bin/env bash
# Part 12 of EC2_QA_Environment_Setup_Guide.txt: build + deploy the website
# (Landers-Web-Site) and admin-dashboard (Admin-Dashboard-Front-End) as static
# Nginx containers.
#
# NOTE the website is a special case (confirmed in the guide's Part 6 naming
# note): landersfolk.com is THE real site, not QA/prod-scoped — its angular.json
# only has production/development configs, no "qa". It's built with the
# "production" Angular configuration on every box; only admin-dashboard has a
# separate "qa" configuration (fileReplacements to environment.qa.ts) that this
# script picks automatically for ENVIRONMENT=qa, or "production" otherwise.
#
# Usage: ./10-deploy-frontend.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"
require_vars WEBSITE_PORT ADMIN_DASHBOARD_PORT

WORKDIR="${HOME}/landers-app"

log "Building + deploying Landers-Web-Site (always 'production' config — see header note)"
( cd "${WORKDIR}/Landers-Web-Site" && \
  npm ci && \
  npm run build -- --configuration=production )
docker build -t "localhost:5000/lander-web:${IMAGE_TAG}" "${WORKDIR}/Landers-Web-Site"
docker push "localhost:5000/lander-web:${IMAGE_TAG}"

ADMIN_ANGULAR_CONFIG="production"
[ "$ENVIRONMENT" = "qa" ] && ADMIN_ANGULAR_CONFIG="qa"
log "Building + deploying Admin-Dashboard-Front-End (Angular config: ${ADMIN_ANGULAR_CONFIG})"
( cd "${WORKDIR}/Admin-Dashboard-Front-End" && \
  npm ci && \
  npm run build -- --configuration="${ADMIN_ANGULAR_CONFIG}" )
docker build -t "localhost:5000/admin-dashboard:${IMAGE_TAG}" "${WORKDIR}/Admin-Dashboard-Front-End"
docker push "localhost:5000/admin-dashboard:${IMAGE_TAG}"

for pair in "lander-web:${WEBSITE_PORT}" "admin-dashboard:${ADMIN_DASHBOARD_PORT}"; do
  name="${pair%%:*}"
  port="${pair##*:}"
  if kubectl get deployment "$name" &>/dev/null; then
    log "[$name] Updating existing deployment"
    kubectl set image "deployment/${name}" "${name}=localhost:5000/${name}:${IMAGE_TAG}"
    kubectl rollout status "deployment/${name}" --timeout=120s
  else
    log "[$name] Creating deployment + service on host port ${port}"
    kubectl create deployment "$name" --image="localhost:5000/${name}:${IMAGE_TAG}"
    kubectl expose deployment "$name" --type=LoadBalancer --port="${port}" --target-port=80
  fi
done

log "Frontend deployed for '${ENVIRONMENT}'."
warn "Remaining manual step (AWS Console, same pattern as QA Part 12.4): ALB target"
warn "groups + listener rules (Host=\${DOMAIN_ROOT} -> lander-web, Host=\${ADMIN_SUBDOMAIN}.\${DOMAIN_ROOT} -> admin-dashboard) + Route53 records."
