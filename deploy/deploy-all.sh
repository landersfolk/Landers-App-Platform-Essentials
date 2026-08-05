#!/usr/bin/env bash
# Orchestrator — runs 01 through 10 in order for one environment, pausing before
# each step that has a real manual/AWS-console prerequisite instead of silently
# failing partway through. This is the "just run the whole guide" entry point;
# run individual deploy/NN-*.sh scripts directly if you're re-doing one step
# (e.g. redeploying services after a code change — see 09-deploy-services.sh,
# or Day-2 "docker build && push && rollout restart" for a single service).
#
# Usage: ./deploy-all.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
ENV_NAME="${1:?Usage: $0 <env-name>}"
load_env "$ENV_NAME"

log "=== Deploying environment '${ENVIRONMENT}' ==="
echo
warn "Prerequisites this script assumes are ALREADY done (AWS Console — see"
warn "VPC_Setup_Guide.txt / EC2_QA_Environment_Setup_Guide.txt Part 0):"
warn "  - VPC, subnets, ALB, security groups, RDS instance"
warn "  - This box's EC2 instance + IAM role"
warn "  - A KMS key for Vault auto-unseal, with envs/${ENVIRONMENT}.env's KMS_KEY_ID set"
warn "  - SSH key registered with GitHub (Part 1.5a)"
confirm "Confirmed all of the above are done — proceed?"

STEPS=(
  "01-bootstrap-host.sh:OS prep, Docker, Node, k3s"
  "02-clone-repos.sh:Clone all repos"
  "03-deploy-vault.sh:Deploy + initialize Vault"
  "04-setup-keycloak.sh:Deploy Keycloak, create realm/clients"
  "06-core-infra.sh:Kafka, Redis, Artifactory"
)

for step in "${STEPS[@]}"; do
  script="${step%%:*}"; desc="${step#*:}"
  log "--- ${desc} (${script}) ---"
  "./${script}" "$ENV_NAME"
done

warn "PAUSE: 05-seed-vault-secrets.sh and 08-configure-configmaps.sh both need"
warn "values only you have (RDS admin password, Keycloak client secrets just"
warn "printed above, DB credentials you're about to generate). Run these two"
warn "manually now, in this order:"
warn "  ./08-configure-configmaps.sh ${ENV_NAME}   # creates the app DB, prints DB creds"
warn "  ./05-seed-vault-secrets.sh ${ENV_NAME}      # seeds Vault using those + Keycloak's secrets"
confirm "Done running both of the above?"

log "--- Build commons-module/data-module (07-build-commons.sh) ---"
./07-build-commons.sh "$ENV_NAME"

log "--- Deploy all 9 services (09-deploy-services.sh) ---"
./09-deploy-services.sh "$ENV_NAME"

log "--- Deploy frontend (10-deploy-frontend.sh) ---"
./10-deploy-frontend.sh "$ENV_NAME"

log "=== '${ENVIRONMENT}' deploy complete. Run ./smoke-test.sh ${ENV_NAME} next. ==="
warn "Remaining manual AWS-console steps (ALB target groups/listener rules,"
warn "Route53 records, ACM cert coverage) were flagged inline by each script above —"
warn "same pattern as QA Parts 6.3/11.2/12.4, not scripted here since you asked to"
warn "scope this automation to what runs on/via the box, not AWS itself."
