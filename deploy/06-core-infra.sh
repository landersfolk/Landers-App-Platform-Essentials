#!/usr/bin/env bash
# Part 7 of EC2_QA_Environment_Setup_Guide.txt: Kafka+Kafdrop, Redis, JFrog
# Artifactory. None of these manifests have environment-specific values (all
# in-cluster only, no RDS/domain dependency) — same file applies unchanged to
# every environment.
#
# Usage: ./06-core-infra.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"

DEPLOYMENTS="${HOME}/landers-app/landers-app-deployments"
INFRA_FILE="${HOME}/landers-app/infrastructure.yaml"

log "Kafka + Kafdrop"
kubectl apply -f "${DEPLOYMENTS}/kafka-and-kafdrop.yaml"

log "Redis"
kubectl apply -f "${DEPLOYMENTS}/redis-qa.yaml"

log "JFrog Artifactory (infrastructure.yaml also has RBAC — applying whole file, per the guide's Part 7.3 note)"
kubectl apply -f "$INFRA_FILE"

log "Cleaning up infrastructure.yaml's unused mysql/postgres/vault-dev resources (RDS + vault-production replace them)"
kubectl delete deployment mysql postgres vault --ignore-not-found
kubectl delete svc mysql-db postgres-db vault-server --ignore-not-found
kubectl delete pvc mysql-data postgres-data --ignore-not-found

log "Making Artifactory reachable at localhost:8082 on the host (needed by 07/09's --network=host docker builds)"
kubectl patch svc jfrog-artifactory -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc jfrog-artifactory

warn "Manual step (one-time, web UI — not scriptable): open http://localhost:8082"
warn "over your SSM/VPN tunnel and complete Artifactory's setup wizard — admin user +"
warn "the local Maven repos matching commons-module/data-module's pom.xml"
warn "<distributionManagement> ids (Part 7.4). Then generate an access token and run:"
warn "  mkdir -p ~/.m2 && cat > ~/.m2/settings.xml   # see Part 7.5 for the exact XML"
warn "before running 07-build-commons.sh."

kubectl get pods -A
