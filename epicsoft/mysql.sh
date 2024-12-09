#!/bin/bash

readonly MYSQLDUMP_START_TIME=$(date +"%Y%m%d-%H%M%S")
readonly MYSQLDUMP_FILE_NAME="${MYSQLDUMP_START_TIME}.${MYSQLDUMP_FILENAME}.sql"
readonly MYSQLDUMP_FILE_PATH="${WORKING_DIR}"
readonly MYSQLDUMP_FILE="${MYSQLDUMP_FILE_PATH}/${MYSQLDUMP_FILE_NAME}"

if [ -z "${MYSQL_HOST}" ]; then
  logError "You need to set the 'MYSQL_HOST' environment variable."
  exit 1
fi

if [ -z "${MYSQL_PORT}" ]; then
  logError "You need to set the 'MYSQL_PORT' environment variable."
  exit 1
fi

if [ -z "${MYSQL_USERNAME}" ]; then
  logError "You need to set the 'MYSQL_USERNAME' environment variable."
  exit 1
fi

if [ -z "${MYSQL_PASSWORD}" ]; then
  logError "You need to set the 'MYSQL_PASSWORD' environment variable."
  exit 1
fi

if [ -z "${MYSQLDUMP_OPTIONS}" ]; then
  logError "You need to set the 'MYSQLDUMP_OPTIONS' environment variable."
  exit 1
fi

if [ -z "${MYSQLDUMP_DATABASES}" ]; then
  logError "You need to set the 'MYSQLDUMP_DATABASES' environment variable."
  exit 1
fi

if [ -z "${MYSQLDUMP_FILENAME}" ]; then
  logError "You need to set the 'MYSQLDUMP_FILENAME' environment variable."
  exit 1
fi

MYSQL_HOST_OPTS="--host=${MYSQL_HOST} --port=${MYSQL_PORT} --user=${MYSQL_USERNAME} --password=${MYSQL_PASSWORD}"

mkdir -p ${MYSQLDUMP_FILE_PATH}
rm -rf ${MYSQLDUMP_FILE}

if [ "${MYSQLDUMP_DATABASES}" == "--all-databases" ]; then
  logInfo "MySQL dump starting for all databases"
  mysqldump ${MYSQL_HOST_OPTS} ${MYSQLDUMP_OPTIONS} ${MYSQLDUMP_ADD_OPTIONS} --all-databases > ${MYSQLDUMP_FILE}
  logInfo "MySQL dump completed for all databases"
else
  logInfo "MySQL dump starting for '${MYSQLDUMP_DATABASES}' database(s)"
  mysqldump ${MYSQL_HOST_OPTS} ${MYSQLDUMP_OPTIONS} ${MYSQLDUMP_ADD_OPTIONS} --databases ${MYSQLDUMP_DATABASES} > ${MYSQLDUMP_FILE}
  logInfo "MySQL dump completed for '${MYSQLDUMP_DATABASES}' database(s)"
fi

readonly __DBBACKUP_FILE_NAME="${MYSQLDUMP_FILE_NAME}"
readonly __DBBACKUP_FILE_PATH="${MYSQLDUMP_FILE_PATH}"
readonly __DBBACKUP_FILE="${MYSQLDUMP_FILE}"

__BACKUP_FILE_NAME="${MYSQLDUMP_FILE_NAME}"
__BACKUP_FILE_PATH="${MYSQLDUMP_FILE_PATH}"
__BACKUP_FILE="${MYSQLDUMP_FILE}"
