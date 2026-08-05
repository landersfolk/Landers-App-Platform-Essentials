#!/usr/bin/env bash
# Part 8 of EC2_QA_Environment_Setup_Guide.txt: dockerized `mvn deploy` of
# commons-module and data-module to this box's Artifactory — no host Maven
# install, same reasoning as every service's own build (see Part 0's "WHY
# JAVA/MAVEN ARE NEVER INSTALLED ON THE HOST"). Not environment-parameterized
# beyond "run it on the right box" — each box has its own Artifactory, so
# there's nothing else to vary here.
#
# Usage: ./07-build-commons.sh <qa|prod|...>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env "${1:?Usage: $0 <env-name>}"

[ -f "${HOME}/.m2/settings.xml" ] || die "No ~/.m2/settings.xml — finish 06-core-infra.sh's Artifactory setup wizard first (Part 7.4/7.5)."

WORKDIR="${HOME}/landers-app"
docker volume create maven-repo-cache >/dev/null

for module in commons-module data-module; do
  log "Building + publishing ${module}"
  docker run --rm --network host \
    -v "${WORKDIR}/${module}":/build -w /build \
    -v "${HOME}/.m2/settings.xml":/root/.m2/settings.xml:ro \
    -v maven-repo-cache:/root/.m2/repository \
    maven:3.9-eclipse-temurin-21 mvn clean deploy
done

log "commons-module + data-module published for '${ENVIRONMENT}'."
