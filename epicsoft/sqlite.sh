#!/bin/bash

# checked before the path is built from it, not with the other variables further down -
# by then the file name would already be part of a readonly path
assertSafeFilename "SQLITE_FILENAME"

readonly SQLITE_START_TIME=$(date +"%Y%m%d-%H%M%S")

if [ -z "${SQLITE_MODE}" ]; then
  SQLITE_MODE="backup"
fi

SQLITE_MODE="$(echo "${SQLITE_MODE}" | tr '[:upper:]' '[:lower:]')"

if [ "${SQLITE_MODE}" != "backup" ] && [ "${SQLITE_MODE}" != "dump" ]; then
  logError "'SQLITE_MODE' must be 'backup' or 'dump'."
  exit 1
fi

# a '.backup' copy is a database file, a '.dump' is SQL text - the extension has
# to say which one it is, otherwise a restore starts with a guess
if [ "${SQLITE_MODE}" == "backup" ]; then
  readonly SQLITE_FILE_EXTENSION="db"
else
  readonly SQLITE_FILE_EXTENSION="sql"
fi

readonly SQLITE_FILE_NAME="${SQLITE_START_TIME}.${SQLITE_FILENAME}.${SQLITE_FILE_EXTENSION}"
readonly SQLITE_FILE_PATH="${DUMP_DIR}"
readonly SQLITE_FILE="${SQLITE_FILE_PATH}/${SQLITE_FILE_NAME}"

if [ -z "${SQLITE_DATABASE}" ]; then
  logError "You need to set the 'SQLITE_DATABASE' environment variable."
  exit 1
fi

# a '.backup' produces one binary file per database and binaries cannot be
# concatenated - so several databases are only possible in dump mode. Failing
# here is better than writing a file that silently holds just the last database.
readonly SQLITE_DATABASE_COUNT=$(echo ${SQLITE_DATABASE} | wc -w)

if [ "${SQLITE_MODE}" == "backup" ] && [ ${SQLITE_DATABASE_COUNT} -gt 1 ]; then
  logError "'SQLITE_MODE=backup' handles exactly one database, got ${SQLITE_DATABASE_COUNT}. Use 'SQLITE_MODE=dump' for several."
  exit 1
fi

for SQLITE_DB in ${SQLITE_DATABASE}; do
  if [ ! -f "${SQLITE_DB}" ]; then
    logError "SQLite database '${SQLITE_DB}' does not exist or is not a file."
    exit 1
  fi

  if [ ! -r "${SQLITE_DB}" ]; then
    logError "SQLite database '${SQLITE_DB}' is not readable. Mount it into the container and check the file owner."
    exit 1
  fi
done

# A database in WAL mode cannot even be READ from a read-only mount: SQLite has
# to create the '-shm' file next to it, and that fails. sqlite3 then only says
# 'unable to open database file', which points at the file instead of at the
# mount - so the cause is checked here and reported by name.
#
# Byte 18 of the header is the write format: 1 is a rollback journal, 2 is WAL.
# It is read with dd instead of sqlite3 because sqlite3 is exactly what cannot
# open the file in this situation.
#
# The directory is not tested with '-w': as root that returns true even on a
# read-only mount. Only an actual write attempt tells the truth.
assertDatabaseIsUsable() {
  local _DB=${1}
  local _DIR="$(dirname "${_DB}")"
  local _FORMAT=""
  local _PROBE="${_DIR}/.dbbackup-write-probe.$$"

  _FORMAT="$(dd if="${_DB}" bs=1 skip=18 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')"

  if [ "${_FORMAT}" != "2" ]; then
    return 0
  fi

  if ( : > "${_PROBE}" ) 2>/dev/null; then
    rm -f "${_PROBE}"
    return 0
  fi

  logError "SQLite database '${_DB}' uses WAL and its directory is not writable."
  logError "SQLite needs to create a '-shm' file next to the database, even to read it."
  logError "Mount the directory read-write. Databases without WAL work read-only."
  exit 1
}

for SQLITE_DB in ${SQLITE_DATABASE}; do
  assertDatabaseIsUsable "${SQLITE_DB}"
done

# the target path is not an argument of sqlite3 but part of a string that sqlite3 parses
# itself, so shell quoting does not reach it. 'SQLITE_FILENAME' is checked, but the
# directory in front of it comes from 'STAGING_DIR' and can hold anything - a single
# quote there would end the dot command argument and turn the rest into another one
#
# a dot command argument in double quotes honours backslash escapes, so backslash and
# double quote are escaped and single quotes need no special treatment
sqliteDotArgument() {
  local _VALUE=${1}

  _VALUE="${_VALUE//\\/\\\\}"
  _VALUE="${_VALUE//\"/\\\"}"

  printf '"%s"' "${_VALUE}"
}

# in SQL a string literal is delimited by single quotes and a single quote inside it is
# written twice - the escaping is a different one than for the dot commands above
sqliteStringLiteral() {
  local _VALUE=${1}

  _VALUE="${_VALUE//\'/\'\'}"

  printf "'%s'" "${_VALUE}"
}

mkdir -p "${SQLITE_FILE_PATH}"
rm -rf "${SQLITE_FILE}"

registerFailureCleanupFile "${SQLITE_FILE}"

runIntegrityCheck() {
  local _DB=${1}
  local _RESULT=""

  if [ -z "$(echo "${SQLITE_INTEGRITY_CHECK}" | grep -i -E "(y|yes|true|1)")" ]; then
    return 0
  fi

  local _CODE=0

  logInfo "SQLite integrity check starting for '${_DB}'"

  # the '|| _CODE=$?' is what makes the check below reachable: a corrupted database is
  # exactly the case where sqlite3 exits non-zero, and 'set -e' would end the run right
  # here - failing correctly, but without ever printing the reason
  _RESULT="$(sqlite3 "${_DB}" 'PRAGMA integrity_check;' 2>&1)" || _CODE=$?

  if [ "${_RESULT}" != "ok" ]; then
    logError "SQLite integrity check failed for '${_DB}' (code: ${_CODE}): ${_RESULT}"
    exit 1
  fi

  logInfo "SQLite integrity check completed for '${_DB}'"
}

if [ "${SQLITE_MODE}" == "backup" ]; then
  # the online backup API is the only safe way while the application keeps
  # writing - a plain copy can catch the database mid-write, and the WAL and
  # shared-memory files belonging to it are not part of the copy either. The
  # result is a self-contained database file that needs neither of them back.
  logInfo "SQLite backup starting for '${SQLITE_DATABASE}'"
  sqlite3 "${SQLITE_DATABASE}" ".backup $(sqliteDotArgument "${SQLITE_FILE}")"
  logInfo "SQLite backup completed for '${SQLITE_DATABASE}'"

  # checking the copy, not the source: this is the file a restore would use, and
  # it is the only engine here where a definitive check is one cheap command
  runIntegrityCheck "${SQLITE_FILE}"
else
  # in dump mode the result is SQL text, so the check has to happen on the
  # source - a dump of a damaged database produces damaged SQL without failing
  logInfo "SQLite dump starting for '${SQLITE_DATABASE}'"
  for SQLITE_DB in ${SQLITE_DATABASE}; do
    runIntegrityCheck "${SQLITE_DB}"
    logInfo "SQLite dump starting for '${SQLITE_DB}' database"
    echo "-- ###############################################################################" >> "${SQLITE_FILE}"
    echo "-- #### SQLite backup database: ${SQLITE_DB}" >> "${SQLITE_FILE}"
    echo "-- ###############################################################################" >> "${SQLITE_FILE}"
    sqlite3 "${SQLITE_DB}" ".dump" >> "${SQLITE_FILE}"
    logInfo "SQLite dump completed for '${SQLITE_DB}' database"
  done
  logInfo "SQLite dump completed for '${SQLITE_DATABASE}'"
fi

# The backup is complete here, so it survives a later failure - and the size report
# below is exactly such a later failure. It is informational, it runs 'VACUUM INTO'
# against the source, and on a malformed database that fails. Releasing the file only
# after the report would let an optional diagnostic delete a finished backup.
clearFailureCleanupFile "${SQLITE_FILE}"

# SQLite never returns deleted pages to the file system, so the file on disk can
# be much larger than the data in it. Reporting both makes the difference
# visible instead of leaving a growing file to be read as growing data.
if [ ! -z "$(echo "${SQLITE_REPORT_SIZE}" | grep -i -E "(y|yes|true|1)")" ]; then
  for SQLITE_DB in ${SQLITE_DATABASE}; do
    SQLITE_VACUUM_FILE="$(mktemp "${DUMP_DIR}/.sqlite-vacuum-XXXXXX")"
    rm -f "${SQLITE_VACUUM_FILE}"
    registerCleanupFile "${SQLITE_VACUUM_FILE}"
    sqlite3 "${SQLITE_DB}" "VACUUM INTO $(sqliteStringLiteral "${SQLITE_VACUUM_FILE}");"
    logInfo "SQLite size of '${SQLITE_DB}': $(stat -c %s "${SQLITE_DB}") bytes on disk, $(stat -c %s "${SQLITE_VACUUM_FILE}") bytes compacted"
  done
fi

readonly __DBBACKUP_FILE_NAME="${SQLITE_FILE_NAME}"
readonly __DBBACKUP_FILE_PATH="${SQLITE_FILE_PATH}"
readonly __DBBACKUP_FILE="${SQLITE_FILE}"

__BACKUP_FILE_NAME="${SQLITE_FILE_NAME}"
__BACKUP_FILE_PATH="${SQLITE_FILE_PATH}"
__BACKUP_FILE="${SQLITE_FILE}"
__BACKUP_FILE_PATTERN="*.${SQLITE_FILENAME}.${SQLITE_FILE_EXTENSION}*"
__BACKUP_DATABASE_HOST="$(hostname)"
__BACKUP_DATABASES="${SQLITE_DATABASE}"
