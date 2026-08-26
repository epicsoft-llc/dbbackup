#!/bin/bash

readonly CRON_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CRON_ENV_FILE="/tmp/dbbackup.env"
readonly CRON_LOCK_FILE="/tmp/dbbackup.lock"

if [ -f "${CRON_ENV_FILE}" ]; then
  source "${CRON_ENV_FILE}"
fi

source "${CRON_SCRIPT_DIR}/utils.sh"

# a long running backup must not be started a second time by the next schedule
exec 9> "${CRON_LOCK_FILE}"
if ! flock -n 9; then
  logWarn "Previous backup is still running - skipping this run"
  exit 0
fi

bash "${CRON_SCRIPT_DIR}/backup.sh"
CRON_BACKUP_RESULT=$?

if [ ${CRON_BACKUP_RESULT} != 0 ]; then
  logError "Backup failed (code: ${CRON_BACKUP_RESULT}) - container keeps running, retry on next run of schedule '${CRON_SCHEDULE}'"
fi

exit ${CRON_BACKUP_RESULT}
