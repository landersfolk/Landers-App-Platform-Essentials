# Vault — production setup

This directory is a **separate, independent production configuration** for HashiCorp
Vault. It does not touch, replace, or depend on the existing local dev Vault (the
`vault` Deployment in k3d, started via `-dev` mode with a hardcoded `root` token,
seeded via `../vault-seed-secrets.sh`, config at `../vault-config.hcl`). That dev setup
keeps working exactly as before — nothing in this directory is wired into it.

## What's different from dev, and why

| | Dev (existing, untouched) | Production (this directory) |
|---|---|---|
| Storage | In-memory (`-dev` mode) — **wiped on every pod restart** | Raft integrated storage, persisted to a PVC |
| TLS | None (plaintext HTTP) | TLS terminated at Vault itself (HashiCorp's own recommendation) |
| Unseal | Auto-unseals (dev mode only) | AWS KMS auto-unseal — no manual Shamir key-share entry after restarts |
| Client auth | Every service shares one hardcoded `root` token | One AppRole identity per service, each scoped to read only its own secret path |
| Root token | `root`, committed in plaintext (`../vault_token.txt`) | Generated once at `vault operator init`, then revoked after bootstrap |

## Files here

- `vault.hcl` — standalone server config reference (the same content is embedded in
  `vault-statefulset.yaml`'s ConfigMap — kept here too as a readable reference/diff target).
- `vault-statefulset.yaml` — Kubernetes ConfigMap + Services + StatefulSet. Read its header
  comment first — it has the full first-time bootstrap sequence.
- `policies/*.hcl` — one least-privilege policy per microservice (read-only, own path only).
- `setup-approle.sh` — one-time script: enables AppRole auth, writes the policies, creates
  one AppRole role per service, prints role_ids and generates secret_ids.
- `seed-secrets-prod.sh` — writes real secrets into a service's production path. Takes every
  value from an environment variable you set immediately before running it — no dummy
  values are hardcoded anywhere in this script (unlike the dev seeder).

## First-time bootstrap, end to end

1. **Provision TLS.** Get a certificate for `vault.landers.com` into a Kubernetes Secret
   named `vault-prod-tls` (keys `tls.crt`/`tls.key`) — via cert-manager (recommended,
   works with a public CA like Let's Encrypt, in which case client services need no
   custom truststore) or your own cert if you're using an internal CA.
2. **Provision the AWS KMS key** referenced in `vault.hcl`'s `seal "awskms"` stanza, and
   grant the Vault pod's IAM role (IRSA on EKS — never a static AWS access key)
   `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on it. Fill in the real region/key ID
   in both `vault.hcl` and `vault-statefulset.yaml`'s embedded copy.
3. `kubectl apply -f vault-statefulset.yaml`
4. **Initialize** (once, ever — re-running this on an already-initialized Vault is a
   no-op error, not a reset):
   ```
   kubectl exec -it vault-prod-0 -- vault operator init -recovery-shares=5 -recovery-threshold=3
   ```
   (Note: `-key-shares`/`-key-threshold` are Shamir-only flags and will fail against a
   seal "awskms" config with "parameters ... not applicable to seal type awskms" — use
   `-recovery-shares`/`-recovery-threshold` instead, as above.)
   This prints 5 recovery key shares and the initial root token. With KMS auto-unseal
   there's no Shamir unseal step needed on ordinary restarts — the recovery keys exist
   only for disaster recovery / re-keying the seal itself, and should be split among
   several people or stored offline (a password manager with strict access control is a
   reasonable minimum; do not put them in this repo).
5. **Bootstrap AppRole auth + policies:**
   ```
   export VAULT_ADDR="https://vault.landers.com:8200"
   export VAULT_TOKEN="<the root token from step 4>"
   ./setup-approle.sh
   ```
   Save the printed `role_id`/`secret_id` pairs into whatever secret store feeds your
   pods' env vars (a Kubernetes Secret per service, synced from AWS Secrets Manager via
   External Secrets Operator, or however you already manage prod secrets — this repo
   doesn't prescribe one).
6. **Revoke the root token** used for bootstrap once step 5 is done — nothing needs it
   again day-to-day (`vault token revoke <root token>`). Keep the recovery keys from
   step 4 for emergencies only.
7. **Seed real secrets**, once per service:
   ```
   export VAULT_ADDR="https://vault.landers.com:8200"
   export VAULT_TOKEN="..."   # an admin-capable token — NOT one of the per-service AppRole tokens
   export SERVICE_NAME="admin-service"
   export KEYCLOAK_CLIENT_SECRET="..." KEYCLOAK_ADMIN_CLIENT_SECRET="..." \
          DB_USERNAME="..." DB_PASSWORD="..."
   ./seed-secrets-prod.sh
   ```
   Repeat for all 9 services. Real values only — pull them from wherever your actual
   production credentials live, never type real secrets into shell history if avoidable
   (prefix the command with a space, if your shell's `HISTCONTROL` is set to
   `ignorespace`, or use `set +o history` / a `.env` file loaded and then deleted).
8. **Point each service at production Vault.** Every service already has an additive
   `prod`-profile Vault override baked into its `application.yml` (see
   `bugfix_vault_production_setup_2026_07_21` memory / this file's own git history for
   which commit added it) — it activates automatically when `SPRING_PROFILES_ACTIVE=prod`
   and expects these env vars on the pod:
   - `VAULT_HOST` — e.g. `vault-prod` (in-cluster) or `vault.landers.com` (external)
   - `VAULT_PORT` — defaults to `8200`
   - `VAULT_ROLE_ID` / `VAULT_SECRET_ID` — from step 5's output, injected via your secret
     store, never committed
   The **dev** profile is completely unaffected by any of this — it keeps using plaintext
   HTTP + the shared `root` token exactly as it does today, no env vars required.

## Ongoing operations

- **secret_id rotation**: `setup-approle.sh`'s roles set `secret_id_ttl=720h` (30 days).
  Generate a fresh one per service before expiry:
  `vault write -f auth/approle/role/<service>-role/secret-id`, then update the pod's
  secret store and roll the deployment.
- **Adding a 10th microservice later**: copy an existing policy file, add the service
  name to `setup-approle.sh`'s `SERVICES` list and re-run it (idempotent for the other 9),
  add the same additive `prod`-profile Vault block to its `application.yml`.
- **Scaling to 3-node HA**: bump `vault-statefulset.yaml`'s `replicas` to 3 and add
  `retry_join` stanzas per peer in the `storage "raft"` block (see HashiCorp's Raft
  reference architecture docs) — or adopt the official `hashicorp/vault` Helm chart at
  that point, which automates this instead of hand-rolling it further here.
- **Audit logging**: not yet enabled by this config. Turn on once initialized:
  `vault audit enable file file_path=/vault/logs/audit.log` (mount an additional volume
  for `/vault/logs` if you want it to persist/ship anywhere).
