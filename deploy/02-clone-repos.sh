#!/usr/bin/env bash
# Part 1.5 of EC2_QA_Environment_Setup_Guide.txt: clone all 14 repos into
# ~/landers-app and symlink the 5 shared-infra dirs out of Platform-Essentials.
# Idempotent — re-running `git pull`s any repo that's already cloned instead of
# failing.
#
# Prerequisite (manual, one-time per box, not scripted): generate an SSH key on
# THIS box and register it at https://github.com/settings/keys — see the guide's
# Part 1.5a. This script assumes that's already done and `ssh -T git@github.com`
# succeeds.
#
# Usage: ./02-clone-repos.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"

ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated" \
  || die "SSH auth to GitHub failed. Register this box's SSH key first (see Part 1.5a of the guide) before running this script."

WORKDIR="${HOME}/landers-app"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

REPOS="Landers-App-Platform-Essentials commons-module data-module gateway-service admin-service user-service landlord-service corporate-service requester-service booking-service payment-service notification-service Landers-Web-Site Admin-Dashboard-Front-End"

for repo in $REPOS; do
  if [ -d "$repo/.git" ]; then
    log "${repo} already cloned, pulling latest"
    git -C "$repo" pull --ff-only || warn "${repo}: pull failed (local changes?) — resolve manually"
  else
    log "Cloning ${repo}"
    git clone "git@github.com:${GITHUB_ORG}/${repo}.git" "$repo" \
      || warn "${repo} clone failed — check the repo name/rename history (see Part 1.5b's landlord-service note) and clone manually"
  fi
done

log "Symlinking shared infra dirs from Platform-Essentials"
for item in landers-app-deployments landers-app-config-maps infrastructure.yaml dashboard-admin.yaml vault-production; do
  [ -e "$item" ] || ln -s "Landers-App-Platform-Essentials/${item}" "$item"
done

log "Repo layout:"
ls -la "$WORKDIR"

warn "Before pushing Platform-Essentials, confirm no real secrets are committed (taks.txt, vault_token.txt, AWS/*.txt, *.pem — see Part 1.5's IMPORTANT note)."
