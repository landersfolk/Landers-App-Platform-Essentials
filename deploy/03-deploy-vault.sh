#!/usr/bin/env bash
# Part 5.3-5.5 of EC2_QA_Environment_Setup_Guide.txt: render vault-statefulset.yaml
# for this environment's KMS key, apply it, initialize Vault if not already
# initialized, and bootstrap AppRole auth + per-service policies.
#
# Prerequisite (AWS Console, manual, one-time per environment — not scripted,
# same as it was for QA per Part 5.1/5.2): a KMS key for this box's Vault
# auto-unseal, and that key's ARN granted to this EC2 instance's IAM role via an
# inline policy (kms:Encrypt/Decrypt/DescribeKey). Put the resulting key ID into
# envs/<env>.env's KMS_KEY_ID before running this.
#
# Usage: ./03-deploy-vault.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"
require_vars AWS_REGION KMS_KEY_ID

[ "$KMS_KEY_ID" != "<FILL IN — from AWS Console after creating the KMS key>" ] \
  || die "envs/${ENVIRONMENT}.env's KMS_KEY_ID is still a placeholder — create the KMS key in AWS Console first (Part 5.1/5.2 of the guide)."

VAULT_DIR="${HOME}/landers-app/vault-production"
[ -d "$VAULT_DIR" ] || die "Expected ${VAULT_DIR} to exist (run 02-clone-repos.sh first)."

RENDERED="/tmp/vault-statefulset.${ENVIRONMENT}.yaml"
log "Rendering vault-statefulset.yaml for ${ENVIRONMENT} (region=${AWS_REGION}, key=${KMS_KEY_ID})"
sed -e "s|__AWS_REGION__|${AWS_REGION}|g" -e "s|__KMS_KEY_ID__|${KMS_KEY_ID}|g" \
  "${VAULT_DIR}/vault-statefulset.yaml" > "$RENDERED"

kubectl apply -f "$RENDERED"

log "Waiting for vault-prod-0 pod to exist"
kubectl wait --for=condition=PodScheduled pod/vault-prod-0 --timeout=120s 2>/dev/null || true
for i in $(seq 1 30); do
  kubectl get pod vault-prod-0 &>/dev/null && break
  sleep 2
done

INIT_STATUS=$(kubectl exec vault-prod-0 -- vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "False")

if [ "$INIT_STATUS" = "True" ]; then
  log "Vault is already initialized — skipping 'vault operator init'."
  warn "If you still have this environment's root token, proceed to run setup-approle.sh manually if it hasn't been run yet."
else
  warn "Vault is NOT initialized. About to run 'vault operator init' — this is a ONE-TIME"
  warn "action per environment. It prints 5 recovery key shares + a root token that will"
  warn "NOT be shown again. Have a password manager open before continuing."
  confirm "Run 'vault operator init' now?"
  kubectl exec -it vault-prod-0 -- vault operator init -recovery-shares=5 -recovery-threshold=3
  echo
  warn "Save every recovery key share + the root token above into a password manager NOW."
  warn "They are not stored anywhere in this repo or by this script."
  read -r -p "Paste the root token here to continue bootstrapping AppRole (input hidden): " -s ROOT_TOKEN
  echo
  export VAULT_ADDR="http://vault-prod.default.svc.cluster.local:8200"
  export VAULT_TOKEN="$ROOT_TOKEN"
  log "Running setup-approle.sh (port-forwarding to reach Vault from outside the pod)"
  kubectl port-forward svc/vault-prod 8200:8200 &
  PF_PID=$!
  sleep 3
  VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="$ROOT_TOKEN" "${VAULT_DIR}/setup-approle.sh" | tee "/tmp/vault-approle-creds.${ENVIRONMENT}.txt"
  kill $PF_PID 2>/dev/null || true
  warn "role_id/secret_id pairs saved to /tmp/vault-approle-creds.${ENVIRONMENT}.txt — move this"
  warn "somewhere safe and delete it from /tmp. You'll need these for 09-deploy-services.sh."
  warn "Revoke the root token now that setup-approle.sh has run (vault token revoke <token>)."
fi

log "Vault deploy for '${ENVIRONMENT}' complete."
