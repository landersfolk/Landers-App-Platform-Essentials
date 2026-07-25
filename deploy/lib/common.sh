# Sourced by every deploy/NN-*.sh script. Not directly executable.

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*"; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# Loads deploy/envs/<name>.env and exports every variable in it.
# Usage: source lib/common.sh && load_env prod
load_env() {
  local env_name="${1:?Usage: load_env <qa|prod|...>}"
  local deploy_dir
  deploy_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  local env_file="${deploy_dir}/envs/${env_name}.env"
  [ -f "$env_file" ] || die "No env file at ${env_file} — copy envs/prod.env.example and fill it in first."
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  : "${ENVIRONMENT:?${env_file} must set ENVIRONMENT}"
  log "Loaded environment '${ENVIRONMENT}' from ${env_file}"
}

require_vars() {
  local missing=0
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      warn "Required variable ${v} is not set"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "Missing required variables above — check your envs/<env>.env file."
}

confirm() {
  local prompt="${1:-Continue?}"
  read -r -p "${prompt} [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) die "Aborted by user." ;;
  esac
}

SERVICES="user-service landlord-service requester-service corporate-service admin-service booking-service payment-service notification-service gateway-service"
