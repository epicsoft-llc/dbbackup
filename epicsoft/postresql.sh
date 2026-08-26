#!/bin/bash

readonly PGSQLDUMP_START_TIME=$(date +"%Y%m%d-%H%M%S")
readonly PGSQLDUMP_FILE_NAME="${PGSQLDUMP_START_TIME}.${PGSQL_FILENAME}.sql"
readonly PGSQLDUMP_FILE_PATH="${WORKING_DIR}"
readonly PGSQLDUMP_FILE="${PGSQLDUMP_FILE_PATH}/${PGSQLDUMP_FILE_NAME}"
readonly PGSQL_ROOT_PATH="/usr/libexec/postgresql${PGSQL_VERSION}"

readSecretFile "PGSQL_PASSWORD"

if [ -z "${PGSQL_HOST}" ]; then
  logError "You need to set the 'PGSQL_HOST' environment variable."
  exit 1
fi

if [ -z "${PGSQL_PORT}" ]; then
  logError "You need to set the 'PGSQL_PORT' environment variable."
  exit 1
fi

if [ -z "${PGSQL_USERNAME}" ]; then
  logError "You need to set the 'PGSQL_USERNAME' environment variable."
  exit 1
fi

if [ -z "${PGSQL_PASSWORD}" ]; then
  logError "You need to set the 'PGSQL_PASSWORD' environment variable."
  exit 1
fi

if [ -z "${PGSQL_DATABASES}" ]; then
  logError "You need to set the 'PGSQL_DATABASES' environment variable."
  exit 1
fi

if [ -z "${PGSQL_VERSION}" ]; then
  logError "You need to set the 'PGSQL_VERSION' environment variable."
  exit 1
fi

mkdir -p ${PGSQLDUMP_FILE_PATH}
rm -rf ${PGSQLDUMP_FILE}

PGSQL_ARGUMENTS="--host=${PGSQL_HOST} --port=${PGSQL_PORT} --username=${PGSQL_USERNAME} --no-password"

if [ "${PGSQL_DATABASES}" == "--all-databases" ]; then
  logInfo "PostgreSQL dump starting for all databases"
  PGPASSWORD="${PGSQL_PASSWORD}" ${PGSQL_ROOT_PATH}/pg_dumpall ${PGSQL_ARGUMENTS} ${PGSQL_OPTIONS} > ${PGSQLDUMP_FILE}
  logInfo "PostgreSQL dump completed for all databases"
else
  logInfo "PostgreSQL dump starting for '${PGSQL_DATABASES}' database(s)"
  for PGSQL_DB in ${PGSQL_DATABASES}; do
    logInfo "PostgreSQL dump starting for '${PGSQL_DB}' database"
    echo "-- ###############################################################################" >> ${PGSQLDUMP_FILE}
    echo "-- #### PostgreSQL backup database: ${PGSQL_DB}" >> ${PGSQLDUMP_FILE}
    echo "-- ###############################################################################" >> ${PGSQLDUMP_FILE}
    PGPASSWORD="${PGSQL_PASSWORD}" ${PGSQL_ROOT_PATH}/pg_dump ${PGSQL_ARGUMENTS} ${PGSQL_OPTIONS} ${PGSQL_DB} >> ${PGSQLDUMP_FILE}
    logInfo "PostgreSQL dump completed for '${PGSQL_DB}' database"
  done
  logInfo "PostgreSQL dump completed for '${PGSQL_DATABASES}' database(s)"
fi

readonly __DBBACKUP_FILE_NAME="${PGSQLDUMP_FILE_NAME}"
readonly __DBBACKUP_FILE_PATH="${PGSQLDUMP_FILE_PATH}"
readonly __DBBACKUP_FILE="${PGSQLDUMP_FILE}"

__BACKUP_FILE_NAME="${PGSQLDUMP_FILE_NAME}"
__BACKUP_FILE_PATH="${PGSQLDUMP_FILE_PATH}"
__BACKUP_FILE="${PGSQLDUMP_FILE}"
