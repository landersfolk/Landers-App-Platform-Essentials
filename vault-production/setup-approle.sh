#!/usr/bin/env bash
# One-time bootstrap for the PRODUCTION Vault: enables AppRole auth, writes each
# service's least-privilege policy, and creates one AppRole per service — replacing the
# dev setup's single shared "root" token with a scoped identity per service.
#
# Run this ONCE against the production Vault (not the dev one), authenticated with the
# initial root token from `vault operator init` (see vault-statefulset.yaml's header
# comment for the full bootstrap sequence). Safe to re-run — every step is idempotent.
#
# Usage:
#   export VAULT_ADDR="https://vault.landers.com:8200"
#   export VAULT_TOKEN="<root token from vault operator init>"
#   ./setup-approle.sh
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR to the production Vault URL, e.g. https://vault.landers.com:8200}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN to a root/admin token — only needed for this one-time bootstrap}"

SERVICES="admin-service landlord-service requester-service gateway-service user-service booking-service payment-service notification-service corporate-service"
POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/policies" && pwd)"

echo "== Enabling KV v2 secrets engine at secret/ (no-op if already enabled) =="
vault secrets enable -path=secret -version=2 kv 2>/dev/null || echo "  (already enabled)"

echo "== Enabling AppRole auth method (no-op if already enabled) =="
vault auth enable approle 2>/dev/null || echo "  (already enabled)"

echo ""
echo "== Writing per-service policies + AppRole roles =="
for svc in $SERVICES; do
  echo "-> ${svc}"
  vault policy write "${svc}-policy" "${POLICY_DIR}/${svc}-policy.hcl"

  # token_ttl/token_max_ttl: short-lived tokens, auto-renewed by Spring Cloud Vault's
  # lease-renewal (already configured client-side, see each service's prod-profile block).
  # secret_id_ttl: the secret_id itself (the "password" half of the AppRole credential
  # pair) expires and must be rotated periodically — treat rotation like any other
  # credential rotation, driven by whatever secret store injects it into the pod.
  vault write "auth/approle/role/${svc}-role" \
    token_policies="${svc}-policy" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=720h \
    secret_id_num_uses=0
done

echo ""
echo "== Role IDs (safe to store alongside app config — not secret on their own) =="
for svc in $SERVICES; do
  role_id=$(vault read -field=role_id "auth/approle/role/${svc}-role/role-id")
  echo "  ${svc}: ${role_id}"
done

echo ""
echo "== Generating one secret_id per service (SECRET — handle like a password) =="
echo "== Inject these into each pod via a K8s Secret / your secret-manager of choice, =="
echo "== never commit them to source control. =="
for svc in $SERVICES; do
  secret_id=$(vault write -field=secret_id -f "auth/approle/role/${svc}-role/secret-id")
  echo "  ${svc}: ${secret_id}"
done

echo ""
echo "Done. Next: seed real secrets per service (see README.md), then point each"
echo "service's prod profile at this Vault via VAULT_ROLE_ID / VAULT_SECRET_ID env vars."
