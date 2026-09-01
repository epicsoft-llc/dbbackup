#!/bin/bash

#### Removes what the test environment created. Runs on its own:
####
####   bash test/clean.sh env      containers, volumes and the network
####   bash test/clean.sh all      additionally the image 'dbbackup:test' and the logs
####   bash test/clean.sh --help   this text
####
#### Called without an argument it prints this help - it removes things, so an
#### accidental call should not be the one that does it.
####
#### 'test.sh' calls 'env' at the end of a run and on an interrupt, but a run that is
#### killed hard leaves things behind. Nothing here has to know what ran: everything the
#### tests create carries the label 'dbbackup-test', so removing by label catches the
#### leftovers of any run in any state - including a container that is still up.

# Git Bash rewrites arguments that look like a unix path into a windows path before
# docker sees them, which turns '/backup' into a directory inside the git installation
export MSYS_NO_PATHCONV=1

readonly CLEAN_LABEL="dbbackup-test"
readonly CLEAN_IMAGE="dbbackup:test"
readonly CLEAN_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CLEAN_LOG_DIR="${CLEAN_DIR}/.logs"

usage() {
  awk '
    /^####/ { started = 1; sub(/^#### ?/, ""); print; next }
    started { exit }
  ' "$0"
}

CLEAN_ALL="false"

case "${1:-}" in
  env ) ;;
  all ) CLEAN_ALL="true" ;;
  --help | -h | "" ) usage; exit 0 ;;
  * ) echo "unknown argument '${1}'"; echo; usage; exit 1 ;;
esac

# the base images of the databases, alpine, busybox and minio are deliberately kept even
# with 'all': they belong to other things too, and pulling them again is the slowest
# part of a run
cleanRemove() {
  local _WHAT=${1}
  local _IDS=${2}
  local _KIND=${3}

  if [ -z "${_IDS}" ]; then
    return 0
  fi

  echo "  removing ${_WHAT}: $(echo "${_IDS}" | wc -w)"
  echo "${_IDS}" | xargs docker "${_KIND}" rm -f > /dev/null 2>&1
}

echo "Cleaning up the test environment"

# containers first - a volume or network still attached to one cannot be removed
cleanRemove "container(s)" "$(docker ps -a -q --filter "label=${CLEAN_LABEL}")" "container"
cleanRemove "volume(s)" "$(docker volume ls -q --filter "label=${CLEAN_LABEL}")" "volume"

CLEAN_NETWORKS="$(docker network ls -q --filter "label=${CLEAN_LABEL}")"

if [ ! -z "${CLEAN_NETWORKS}" ]; then
  echo "  removing network(s): $(echo "${CLEAN_NETWORKS}" | wc -w)"
  echo "${CLEAN_NETWORKS}" | xargs docker network rm > /dev/null 2>&1
fi

if [ "${CLEAN_ALL}" == "true" ]; then
  if [ ! -z "$(docker image ls -q "${CLEAN_IMAGE}")" ]; then
    echo "  removing image '${CLEAN_IMAGE}'"
    docker image rm -f "${CLEAN_IMAGE}" > /dev/null 2>&1
  fi

  if [ -d "${CLEAN_LOG_DIR}" ]; then
    echo "  removing logs"
    rm -rf "${CLEAN_LOG_DIR}"
  fi
fi

echo "Done"
