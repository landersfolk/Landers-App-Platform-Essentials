#!/usr/bin/env bash
# Part 1.2-1.4 + Part 2 + Part 3 + Part 4 of EC2_QA_Environment_Setup_Guide.txt:
# OS prep, Docker + local registry, Node.js, k3s. Identical for every environment
# except the hostname — everything else in these parts was already
# environment-agnostic in the manual guide, just tedious to retype.
#
# Run ON the target EC2 box (not your laptop), as the ubuntu user.
# Idempotent: safe to re-run after a partial failure.
#
# Usage: ./01-bootstrap-host.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"

log "OS prep"
sudo apt-get update && sudo apt-get -y upgrade
sudo timedatectl set-timezone UTC
sudo hostnamectl set-hostname "${EC2_HOSTNAME}"
sudo apt-get install -y curl wget git unzip jq net-tools \
  ca-certificates gnupg lsb-release apache2-utils postgresql-client

log "Swap off"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

log "Kernel limits for Kafka/k8s"
sudo tee /etc/sysctl.d/99-landers-k8s.conf > /dev/null <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
vm.max_map_count = 262144
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

if ! command -v docker &>/dev/null; then
  log "Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  warn "Added $USER to the docker group — log out/in (or start a new shell) before running later scripts."
else
  log "Docker already installed, skipping"
fi

log "Enabling BuildKit"
sudo mkdir -p /etc/docker
echo '{ "features": { "buildkit": true } }' | sudo tee /etc/docker/daemon.json > /dev/null
sudo systemctl restart docker
grep -q DOCKER_BUILDKIT ~/.bashrc || echo 'export DOCKER_BUILDKIT=1' >> ~/.bashrc
export DOCKER_BUILDKIT=1

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^registry$'; then
  log "Starting local image registry"
  docker volume create registry-data
  docker run -d --name registry --restart always \
    -p 127.0.0.1:5000:5000 \
    -v registry-data:/var/lib/registry \
    registry:2
else
  log "Local registry already running, skipping"
fi

if ! command -v node &>/dev/null; then
  log "Installing Node.js 20 LTS + Angular CLI"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  sudo npm install -g @angular/cli
else
  log "Node already installed, skipping"
fi

if ! command -v k3s &>/dev/null; then
  log "Installing k3s (Traefik disabled — the ALB does TLS termination/routing)"
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik
else
  log "k3s already installed, skipping"
fi

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER" ~/.kube/config

log "Pointing k3s's containerd at the local registry"
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
EOF
sudo systemctl restart k3s

log "Waiting for k3s node to be Ready"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes -o wide

log "Host bootstrap for '${ENVIRONMENT}' complete."
warn "Prerequisite (AWS-side, not scripted here): VPC/ALB/security groups/RDS/KMS key/IAM role for this box must already exist — see VPC_Setup_Guide.txt and this env's KMS_KEY_ID in envs/${ENVIRONMENT}.env."
