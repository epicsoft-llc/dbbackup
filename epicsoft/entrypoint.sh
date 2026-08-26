#!/bin/bash

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CRON_DIR="/etc/crontabs"
readonly CRON_FILE="${CRON_DIR}/root"
readonly CRON_ENV_FILE="/tmp/dbbackup.env"

source "${SCRIPT_DIR}/utils.sh"

if [ -z "${CRON_SCHEDULE}" ]; then
  logInfo "Cron disabled - running backup once"
  exec bash "${SCRIPT_DIR}/backup.sh"
fi

logInfo "Cron enabled with schedule '${CRON_SCHEDULE}' (timezone: ${TZ:-UTC}, local time: $(date +%Y%m%d-%H%M%S))"

# cron jobs do not inherit the container environment, so snapshot it for cron.sh
export -p > "${CRON_ENV_FILE}"
chmod 0600 "${CRON_ENV_FILE}"

mkdir -p "${CRON_DIR}"
echo "${CRON_SCHEDULE} ${SCRIPT_DIR}/cron.sh > /proc/1/fd/1 2> /proc/1/fd/2" > "${CRON_FILE}"
chmod 0600 "${CRON_FILE}"

if [ ! -z "$(echo ${CRON_RUN_ON_START} | grep -i -E "(y|yes|true|1)")" ]; then
  logInfo "Initial backup on start"
  bash "${SCRIPT_DIR}/cron.sh" || true
fi

logInfo "Waiting for next run of schedule '${CRON_SCHEDULE}'"
exec crond -f -d 8 -c "${CRON_DIR}"
