# Stock jenkins/jenkins image has neither the docker CLI nor kubectl, both of which
# our pipelines need (docker build/push against the Artifactory-backed images, kubectl
# apply/rollout restart against this same k3s cluster). Adds both on top of the
# official LTS image rather than reinventing Jenkins itself.
FROM jenkins/jenkins:lts-jdk21

USER root

# Docker CLI only (not the daemon) - the daemon is the HOST's, reached via the
# docker.sock bind-mount in jenkins-deployment.yaml. Version pinned loosely to
# whatever's current in Docker's own apt repo, matching the host's install method.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# kubectl - version matches this cluster's k3s-bundled kubectl (check `kubectl version`
# on the EC2 box if k3s gets upgraded later; this is a reasonable current default).
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# Stays root (not `USER jenkins`) so it can use the host's docker.sock bind-mount
# without GID-matching gymnastics - a deliberate, informed trade-off: Docker socket
# access is already root-equivalent host access regardless of the container's own
# UID, so this doesn't meaningfully increase risk beyond what socket access already
# implies. See jenkins-deployment.yaml's comment for the corresponding pod spec.
