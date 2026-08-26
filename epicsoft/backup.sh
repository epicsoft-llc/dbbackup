#!/bin/bash

set -e

readonly SCRIPT_DIR="$(dirname "$0")"
readonly WORKING_DIR="/backup"

source "${SCRIPT_DIR}/utils.sh"

readonly BACKUP_START_EPOCH="$(date +%s)"
readonly BACKUP_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly BACKUP_STATE_FILE="/tmp/dbbackup.state"

# the stages fill these in as they go, so whatever is known at the time of the
# notification is reported - on a failure that can be nothing at all
__BACKUP_TYPE=""
__BACKUP_DATABASE_HOST=""
__BACKUP_DATABASES=""
__BACKUP_COMPRESSED="false"
__BACKUP_ENCRYPTED="false"
__BACKUP_S3_TARGET=""

buildWebhookBody() {
  local _STATUS=${1}
  local _CODE=${2}
  local _SIZE=""

  if [ ! -z "${__BACKUP_FILE}" ] && [ -f "${__BACKUP_FILE}" ]; then
    _SIZE="$(stat -c %s "${__BACKUP_FILE}")"
  fi

  printf '{"status":%s,"backup":%s,"hostname":%s,"database_host":%s,"databases":%s,"started_at":%s,"finished_at":%s,"duration_seconds":%s,"exit_code":%s,"file_name":%s,"file_path":%s,"file_size":%s,"compressed":%s,"encrypted":%s,"s3_target":%s}' \
    "$(jsonValue "${_STATUS}")" \
    "$(jsonValue "${__BACKUP_TYPE}")" \
    "$(jsonValue "$(hostname)")" \
    "$(jsonValue "${__BACKUP_DATABASE_HOST}")" \
    "$(jsonValue "${__BACKUP_DATABASES}")" \
    "$(jsonValue "${BACKUP_STARTED_AT}")" \
    "$(jsonValue "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$(jsonNumber "$(($(date +%s) - BACKUP_START_EPOCH))")" \
    "$(jsonNumber "${_CODE}")" \
    "$(jsonValue "${__BACKUP_FILE_NAME}")" \
    "$(jsonValue "${__BACKUP_FILE_PATH}")" \
    "$(jsonNumber "${_SIZE}")" \
    "${__BACKUP_COMPRESSED}" \
    "${__BACKUP_ENCRYPTED}" \
    "$(jsonValue "${__BACKUP_S3_TARGET}")"
}

# a failing stage exits the whole script, so the notification has to hang off EXIT -
# that is the only place that sees a validation error, a broken dump and a good run alike
onBackupExit() {
  local _CODE=${1}
  local _STATUS="success"
  local _URL="${WEBHOOK_SUCCESS_URL}"

  # the healthcheck reads this to tell a working container from one that only looks alive
  echo "$(date +%s) ${_CODE}" > "${BACKUP_STATE_FILE}"

  removeCleanupFiles

  if [ ${_CODE} != 0 ]; then
    _STATUS="failure"
    _URL="${WEBHOOK_FAILURE_URL}"
    removeFailureCleanupFiles
  fi

  if [ -z "${_URL}" ]; then
    return 0
  fi

  callWebhook "${_URL}" "${_STATUS}" "${WEBHOOK_METHOD}" "$(buildWebhookBody "${_STATUS}" "${_CODE}")"
}

readSecretFile "WEBHOOK_SUCCESS_URL"
readSecretFile "WEBHOOK_FAILURE_URL"

if [ -z "${WEBHOOK_METHOD}" ]; then
  WEBHOOK_METHOD="GET"
fi

WEBHOOK_METHOD="$(echo "${WEBHOOK_METHOD}" | tr '[:lower:]' '[:upper:]')"

if [ "${WEBHOOK_METHOD}" != "GET" ] && [ "${WEBHOOK_METHOD}" != "POST" ]; then
  logError "'WEBHOOK_METHOD' must be 'GET' or 'POST'."
  exit 1
fi

trap 'onBackupExit $?' EXIT

# bash would die on a signal without running the EXIT handler, so route the usual
# shutdown signals through a normal exit
trap 'exit 143' TERM
trap 'exit 130' INT

logInfo "Backup starting"

if [ -z "${BACKUP}" ]; then
  logError "You need to set the 'BACKUP' environment variable."
  exit 1
fi

case ${BACKUP} in
  "MySQL" | "MYSQL" | "mysql" | "MY" | "my" )
    logInfo "MySQL backup starting"
    __BACKUP_TYPE="mysql"
    source "${SCRIPT_DIR}/mysql.sh"
    logInfo "MySQL backup completed"
    ;;
  "MariaDB" | "MARIADB" | "mariadb" | "MARIA" | "maria" )
    logInfo "MariaDB backup starting"
    __BACKUP_TYPE="mariadb"
    source "${SCRIPT_DIR}/mariadb.sh"
    logInfo "MariaDB backup completed"
    ;;
  "PostgreSQL" | "POSTGRESQL" | "postgresql" | "POSTGRES" | "postgres" | "PSQL" | "psql" | "PGSQL" | "pgsql" )
    logInfo "PostgreSQL backup starting"
    __BACKUP_TYPE="pgsql"
    source "${SCRIPT_DIR}/postresql.sh"
    logInfo "PostgreSQL backup completed"
    ;;
  * )
    logError "Backup '${BACKUP}' not supported"
    exit 1
    ;;
esac

if [ ! -z "$(echo "${COMPRESS_ENABLE}" | grep -i -E "(y|yes|true|1)")" ]; then
  logInfo "Compress starting"
  source "${SCRIPT_DIR}/7zip.sh"
  logInfo "Compress completed"
else
  logInfo "Compress disabled"
fi

if [ ! -z "$(echo "${S3_ENABLE}" | grep -i -E "(y|yes|true|1)")" ]; then
  logInfo "S3 upload starting"
  source "${SCRIPT_DIR}/s3.sh"
  logInfo "S3 upload completed"
else
  logInfo "S3 upload disabled"
fi

if [ ! -z "${RETENTION_KEEP_LAST}" ] || [ ! -z "${RETENTION_KEEP_DAYS}" ]; then
  logInfo "Retention starting"
  source "${SCRIPT_DIR}/retention.sh"
  logInfo "Retention completed"
else
  logInfo "Retention disabled"
fi

logInfo "Backup completed"
