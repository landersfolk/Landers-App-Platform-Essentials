#!/usr/bin/env bash
# Part 10-11 of EC2_QA_Environment_Setup_Guide.txt: for each of the 9 services —
# create its VAULT_ROLE_ID/SECRET_ID k8s Secret, build the image, push it, render
# + apply its Deployment/Service — in the dependency-ish order the guide
# recommends (gateway-service last, since it's the only one the ALB needs Ready).
#
# Usage: ./09-deploy-services.sh <qa|prod|...> [approle-creds-file]
#   approle-creds-file defaults to /tmp/vault-approle-creds.<env>.txt (03-deploy-vault.sh's output)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name> [approle-creds-file]}"
require_vars IMAGE_TAG

CREDS_FILE="${2:-/tmp/vault-approle-creds.${ENVIRONMENT}.txt}"
[ -f "$CREDS_FILE" ] || die "No AppRole creds file at ${CREDS_FILE} — run 03-deploy-vault.sh first, or pass its saved output path as \$2."

[ -f "${HOME}/.m2/settings.xml" ] || die "No ~/.m2/settings.xml — finish 06-core-infra.sh's Artifactory setup wizard first."

WORKDIR="${HOME}/landers-app"
DEPLOYMENTS="${WORKDIR}/landers-app-deployments"

role_id_for()   { awk -v svc="$1" '/^== Role IDs/{f=1} /^== Generating/{f=0} f && $0 ~ "  "svc": " {print $NF}' "$CREDS_FILE"; }
secret_id_for() { awk -v svc="$1" '/^== Generating/{f=1} /^Done\./{f=0} f && $0 ~ "  "svc": " {print $NF}' "$CREDS_FILE"; }

# gateway-service last — it's the only one the ALB target group needs Ready, and
# every other service should exist first for Spring Cloud Kubernetes discovery.
ORDERED_SERVICES="user-service landlord-service requester-service corporate-service admin-service booking-service payment-service notification-service gateway-service"

for svc in $ORDERED_SERVICES; do
  role_id=$(role_id_for "$svc")
  secret_id=$(secret_id_for "$svc")
  [ -n "$role_id" ] && [ -n "$secret_id" ] || die "Could not find role_id/secret_id for ${svc} in ${CREDS_FILE} — check the file's format matches setup-approle.sh's output."

  if ! kubectl get secret "${svc}-vault-creds" &>/dev/null; then
    log "[$svc] Creating Vault AppRole k8s Secret"
    kubectl create secret generic "${svc}-vault-creds" \
      --from-literal=role_id="$role_id" \
      --from-literal=secret_id="$secret_id"
  fi

  # Dockerfile is now runtime-only (just copies target/*.jar in) -- the jar
  # has to be built here first, mvn no longer runs inside the docker build.
  log "[$svc] Building jar"
  ( cd "${WORKDIR}/${svc}" && mvn -B clean package -DskipTests )

  log "[$svc] Building image (localhost:5000/${svc}:${IMAGE_TAG})"
  ( cd "${WORKDIR}/${svc}" && \
    docker build --network=host \
      -t "localhost:5000/${svc}:${IMAGE_TAG}" . )

  log "[$svc] Pushing image"
  docker push "localhost:5000/${svc}:${IMAGE_TAG}"

  RENDERED="/tmp/${svc}-deployment.${ENVIRONMENT}.yaml"
  sed -e "s|__IMAGE_TAG__|${IMAGE_TAG}|g" -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
    "${DEPLOYMENTS}/${svc}-deployment.yaml" > "$RENDERED"

  log "[$svc] Applying Deployment + Service"
  kubectl apply -f "$RENDERED"
  kubectl rollout status "deployment/${svc}" --timeout=180s || warn "[$svc] rollout didn't reach Ready in time — check 'kubectl logs deploy/${svc}'"
done

log "All 9 services deployed for '${ENVIRONMENT}'."
kubectl get pods -o wide

warn "Remaining manual step (AWS Console, same pattern as QA Part 11.2): confirm"
warn "gateway-service's Service is type LoadBalancer bound to host port 7070, then"
warn "wire the ALB target group 'landers-app-tg' + listener rule (Host header ="
warn "\${API_SUBDOMAIN}.\${DOMAIN_ROOT}) + Route53 record to it."
