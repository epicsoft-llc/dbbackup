#!/bin/bash

set -e

readonly SCRIPT_DIR="$(dirname "$0")"
readonly WORKING_DIR="/backup"

source "${SCRIPT_DIR}/utils.sh"

logInfo "Backup starting"

if [ -z "${BACKUP}" ]; then
  logError "You need to set the 'BACKUP' environment variable."
  exit 1
fi

case ${BACKUP} in
  "MySQL" | "MYSQL" | "mysql" | "MY" | "my" )
    logInfo "MySQL backup starting"
    source "${SCRIPT_DIR}/mysql.sh"
    logInfo "MySQL backup completed"
    ;;
  "MariaDB" | "MARIADB" | "mariadb" | "MARIA" | "maria" )
    logInfo "MariaDB backup starting"
    source "${SCRIPT_DIR}/mariadb.sh"
    logInfo "MariaDB backup completed"
    ;;
  "PostgreSQL" | "POSTGRESQL" | "postgresql" | "POSTGRES" | "postgres" | "PSQL" | "psql" | "PGSQL" | "pgsql" )
    logInfo "PostgreSQL backup starting"
    source "${SCRIPT_DIR}/postresql.sh"
    logInfo "PostgreSQL backup completed"
    ;;
  * )
    logError "Backup '${BACKUP}' not supported"
    exit 1
    ;;
esac

if [ ! -z "$(echo ${COMPRESS_ENABLE} | grep -i -E "(y|yes|true|1)")" ]; then
  logInfo "Compress starting"
  source "${SCRIPT_DIR}/7zip.sh"
  logInfo "Compress completed"
else
  logInfo "Compress disabled"
fi

if [ ! -z "$(echo ${S3_ENABLE} | grep -i -E "(y|yes|true|1)")" ]; then
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
