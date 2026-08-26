#!/bin/bash

readonly MARIADBDUMP_START_TIME=$(date +"%Y%m%d-%H%M%S")
readonly MARIADBDUMP_FILE_NAME="${MARIADBDUMP_START_TIME}.${MARIADBDUMP_FILENAME}.sql"
readonly MARIADBDUMP_FILE_PATH="${WORKING_DIR}"
readonly MARIADBDUMP_FILE="${MARIADBDUMP_FILE_PATH}/${MARIADBDUMP_FILE_NAME}"

readSecretFile "MARIADB_PASSWORD"

if [ -z "${MARIADB_HOST}" ]; then
  logError "You need to set the 'MARIADB_HOST' environment variable."
  exit 1
fi

if [ -z "${MARIADB_PORT}" ]; then
  logError "You need to set the 'MARIADB_PORT' environment variable."
  exit 1
fi

if [ -z "${MARIADB_USERNAME}" ]; then
  logError "You need to set the 'MARIADB_USERNAME' environment variable."
  exit 1
fi

if [ -z "${MARIADB_PASSWORD}" ]; then
  logError "You need to set the 'MARIADB_PASSWORD' environment variable."
  exit 1
fi

if [ -z "${MARIADBDUMP_OPTIONS}" ]; then
  logError "You need to set the 'MARIADBDUMP_OPTIONS' environment variable."
  exit 1
fi

if [ -z "${MARIADBDUMP_DATABASES}" ]; then
  logError "You need to set the 'MARIADBDUMP_DATABASES' environment variable."
  exit 1
fi

if [ -z "${MARIADBDUMP_FILENAME}" ]; then
  logError "You need to set the 'MARIADBDUMP_FILENAME' environment variable."
  exit 1
fi

# the password is passed in an option file instead of on the command line, where any
# process in the container - and 'docker top' on the host - would be able to read it
readonly MARIADB_DEFAULTS_FILE="$(mktemp)"
trap 'rm -f "${MARIADB_DEFAULTS_FILE}"' EXIT
chmod 0600 "${MARIADB_DEFAULTS_FILE}"
writeClientPasswordFile "${MARIADB_DEFAULTS_FILE}" "${MARIADB_PASSWORD}"

MARIADB_HOST_OPTS="--defaults-extra-file=${MARIADB_DEFAULTS_FILE} --host=${MARIADB_HOST} --port=${MARIADB_PORT} --user=${MARIADB_USERNAME}"

mkdir -p ${MARIADBDUMP_FILE_PATH}
rm -rf ${MARIADBDUMP_FILE}

if [ "${MARIADBDUMP_DATABASES}" == "--all-databases" ]; then
  logInfo "MariaDB dump starting for all database(s)"
  mariadb-dump ${MARIADB_HOST_OPTS} ${MARIADBDUMP_OPTIONS} ${MARIADBDUMP_ADD_OPTIONS} --all-databases > ${MARIADBDUMP_FILE}
  logInfo "MariaDB dump completed for all database(s)"
else
  logInfo "MariaDB dump starting for '${MARIADBDUMP_DATABASES}' databases"
  mariadb-dump ${MARIADB_HOST_OPTS} ${MARIADBDUMP_OPTIONS} ${MARIADBDUMP_ADD_OPTIONS} --databases ${MARIADBDUMP_DATABASES} > ${MARIADBDUMP_FILE}
  logInfo "MariaDB dump completed for '${MARIADBDUMP_DATABASES}' databases"
fi

readonly __DBBACKUP_FILE_NAME="${MARIADBDUMP_FILE_NAME}"
readonly __DBBACKUP_FILE_PATH="${MARIADBDUMP_FILE_PATH}"
readonly __DBBACKUP_FILE="${MARIADBDUMP_FILE}"

__BACKUP_FILE_NAME="${MARIADBDUMP_FILE_NAME}"
__BACKUP_FILE_PATH="${MARIADBDUMP_FILE_PATH}"
__BACKUP_FILE="${MARIADBDUMP_FILE}"
__BACKUP_FILE_PATTERN="*.${MARIADBDUMP_FILENAME}.sql*"
