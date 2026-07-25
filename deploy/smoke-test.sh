#!/usr/bin/env bash
# Part 14 of EC2_QA_Environment_Setup_Guide.txt, automated. Run after deploy-all.sh
# (or after wiring the ALB/Route53 manually) to confirm the environment is actually
# healthy end-to-end, not just "pods say Running".
#
# Usage: ./smoke-test.sh <qa|prod|...> [test-username] [test-password]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name> [test-username] [test-password]}"

API_BASE="https://${API_SUBDOMAIN}.${DOMAIN_ROOT}"
WEB_BASE="https://${DOMAIN_ROOT}"
ADMIN_BASE="https://${ADMIN_SUBDOMAIN}.${DOMAIN_ROOT}"
KEYCLOAK_BASE="https://${KEYCLOAK_SUBDOMAIN}.${DOMAIN_ROOT}"

PASS=0
FAIL=0
check() {
  local desc="$1"; shift
  if "$@"; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL+1))
  fi
}

log "Cluster state"
check "all pods Running (0 unexpected restarts to check manually)" \
  bash -c "kubectl get pods --no-headers | awk '{print \$3}' | grep -qv Running && exit 1 || exit 0"
check "no LoadBalancer service stuck <pending>" \
  bash -c "! kubectl get svc --no-headers | grep -q '<pending>'"

log "Public endpoints"
check "Keycloak realm metadata reachable (${KEYCLOAK_BASE})" \
  bash -c "curl -fsS -o /dev/null '${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}'"
check "Website loads (${WEB_BASE})" \
  bash -c "curl -fsS -o /dev/null '${WEB_BASE}/'"
check "Admin dashboard loads (${ADMIN_BASE})" \
  bash -c "curl -fsS -o /dev/null '${ADMIN_BASE}/'"
check "Gateway health is UP (${API_BASE}/actuator/health)" \
  bash -c "curl -fsS '${API_BASE}/actuator/health' | grep -q '\"status\":\"UP\"'"

TEST_USER="${2:-}"
TEST_PASS="${3:-}"
if [ -n "$TEST_USER" ] && [ -n "$TEST_PASS" ]; then
  log "Real login flow (proves Keycloak + gateway-service + issuer-uri are correctly wired)"
  LOGIN_RESPONSE=$(curl -fsS -X POST "${API_BASE}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${TEST_USER}\",\"password\":\"${TEST_PASS}\"}" || echo '{}')
  JWT=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken') or json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
  if [ -n "$JWT" ]; then
    echo "  [PASS] Login returned a JWT"
    PASS=$((PASS+1))
    check "Authenticated GET succeeds (not 401 — catches issuer-uri/jwk-set-uri mismatches)" \
      bash -c "curl -fsS -o /dev/null -H 'Authorization: Bearer ${JWT}' '${API_BASE}/api/v1/users/me' || curl -fsS -o /dev/null -H 'Authorization: Bearer ${JWT}' '${API_BASE}/api/v1/admin/health'"
  else
    echo "  [FAIL] Login did not return a JWT — response: ${LOGIN_RESPONSE}"
    FAIL=$((FAIL+1))
  fi
else
  warn "No test-username/test-password given — skipping the actual login flow check."
  warn "This is the check that would have caught the issuer-uri silent-401 class of bug"
  warn "— worth running manually once you have a test user: ./smoke-test.sh ${ENVIRONMENT} <user> <pass>"
fi

echo
log "Flyway migrations (spot-check via one service's pod)"
kubectl exec deploy/user-service -- sh -c 'true' &>/dev/null \
  && echo "  (user-service pod reachable — check flyway_schema_history via psql manually for full confirmation)" \
  || warn "  user-service pod not reachable, skipped"

echo
log "Results: ${PASS} passed, ${FAIL} failed."
[ "$FAIL" -eq 0 ] || exit 1
