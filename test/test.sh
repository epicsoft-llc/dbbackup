#!/bin/bash

#### Local test environment for the dbbackup image. Everything happens in containers:
#### the databases, the backup target (a named volume) and the webhook receiver. Nothing
#### is written to the host except the logs under 'test/.logs'.
####
####   bash test/test.sh default            unit mariadb pgsql sqlite secrets features cron
####   bash test/test.sh all                additionally 'mysql' and 's3'
####   bash test/test.sh mariadb cron       only these groups
####   bash test/test.sh --keep default     leave the containers up afterwards
####   bash test/test.sh --list             print the group names
####   bash test/test.sh --help             this text
####
#### Called without an argument it prints this help: the run takes minutes and pulls
#### database images, so it is not what an accidental call should start.
####
#### Clean up with 'bash test/clean.sh env', which this script also does on its own at the
#### end of a run and on an interrupt.

# Everything created here carries the docker label 'dbbackup-test'. That is what lets
# 'clean.sh' remove the leftovers of an interrupted run without knowing what ran.
#
# Deliberately without 'set -e': a failed assertion has to be counted and the run has to
# continue, otherwise the first failure hides all the others.

# Git Bash rewrites arguments that look like a unix path into a windows path before
# docker sees them, which turns '/backup' into a directory inside the git installation
export MSYS_NO_PATHCONV=1

readonly TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
readonly LOG_DIR="${TEST_DIR}/.logs"

readonly LABEL="dbbackup-test"
readonly PREFIX="dbbackup-test"
readonly IMAGE="dbbackup:test"
readonly NETWORK="${PREFIX}-net"
readonly BACKUP_VOLUME="${PREFIX}-backup"
readonly SECRET_VOLUME="${PREFIX}-secrets"

readonly ALPINE_IMAGE="alpine:latest"
# alpine's busybox is built without httpd, the standalone busybox image has it
readonly BUSYBOX_IMAGE="busybox:latest"
readonly MARIADB_IMAGE="mariadb:11"
readonly MYSQL_IMAGE="mysql:8.4"
readonly PGSQL_IMAGE="postgres:17"
readonly MINIO_IMAGE="minio/minio:latest"

readonly MARIADB_HOST="${PREFIX}-mariadb"
readonly MYSQL_HOST="${PREFIX}-mysql"
readonly PGSQL_HOST="${PREFIX}-pgsql"
readonly WEBHOOK_HOST="${PREFIX}-webhook"
readonly MINIO_HOST="${PREFIX}-minio"

# Throwaway credentials for containers that exist for the length of one run, are only
# reachable on this machine's own docker network and are removed at the end. They are
# fixtures, not secrets - nothing here is or has ever been a real credential.
#
# The password carries the characters that broke the option file before it was escaped:
# double quote, backslash, space and the comment character.
readonly DB_PASSWORD='pa"ss\wo rd#1'
readonly ROOT_PASSWORD='root-pw-1'

# what has to survive a dump - proves the dump holds data and not just a header
readonly MARKER='dbbackup-marker-42'

readonly DEFAULT_GROUPS="unit mariadb pgsql sqlite secrets features cron"
readonly ALL_GROUPS="unit mariadb mysql pgsql sqlite secrets features cron s3"

readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RED='\033[0;31m'

KEEP="false"
TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_NAMES=()
RUN_OUTPUT=""
RUN_LOG=""

###############################################################################
#### Reporting
###############################################################################

section() {
  printf '\n\033[1m%s\033[0m\n' "${1}"
}

info() {
  printf '  ..   %s\n' "${1}"
}

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf "  ${COLOR_GREEN}PASS${COLOR_RESET} %s\n" "${1}"
}

# the reason is printed right here, the full container log only on a failure - that is
# what keeps a green run to one line per case
fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_NAMES+=("${1}")

  printf "  ${COLOR_RED}FAIL${COLOR_RESET} %s\n" "${1}"

  if [ ! -z "${2}" ]; then
    printf '       %s\n' "${2}"
  fi

  if [ ! -z "${RUN_LOG}" ] && [ -f "${RUN_LOG}" ]; then
    printf '       log: %s\n' "${RUN_LOG}"
    sed -n '$p' "${RUN_LOG}" | sed 's/^/       last: /'
  fi
}

skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf "  ${COLOR_YELLOW}SKIP${COLOR_RESET} %s (%s)\n" "${1}" "${2}"
}

assertEquals() {
  if [ "${2}" == "${3}" ]; then
    pass "${1}"
  else
    fail "${1}" "expected '${2}', got '${3}'"
  fi
}

# compared with 'grep -F' and not with a case pattern: the needles include the test
# password, and a backslash in a case pattern escapes the next character - 'pa"ss\wo'
# would then match a haystack holding 'pa"sswo' and turn a leak into a pass
containsText() {
  printf '%s' "${1}" | grep -q -F -- "${2}"
}

# the haystack goes into the message: 'not found' alone does not say whether the value
# was wrong or whether the command that produced it failed and returned its error instead
assertContains() {
  if containsText "${2}" "${3}"; then
    pass "${1}"
  else
    # the tail, not the head: a run that went wrong says so in its last lines, and its
    # first lines are the same 'Backup starting' banner every time
    fail "${1}" "'${3}' not found in: ...$(printf '%s' "${2}" | tr '\n' ' ' | tail -c 200)"
  fi
}

assertNotContains() {
  if containsText "${2}" "${3}"; then
    fail "${1}" "'${3}' should not appear in the output"
  else
    pass "${1}"
  fi
}

assertFails() {
  if [ "${2}" == "0" ]; then
    fail "${1}" "the run succeeded but should have been rejected"
    return 1
  fi

  pass "${1}"
}

###############################################################################
#### Docker helpers
###############################################################################

# pulled ahead of the run: the progress of a pull goes to stderr and would bury the one
# line per test case that the report is supposed to be
pullImage() {
  if [ ! -z "$(docker image ls -q "${1}")" ]; then
    return 0
  fi

  info "pulling ${1}"
  docker pull -q "${1}" >> "${LOG_DIR}/docker.log" 2>&1
}

dockerRun() {
  docker run -d --name "${1}" --network "${NETWORK}" --label "${LABEL}" "${@:2}" \
    > /dev/null 2>> "${LOG_DIR}/docker.log"
}

# runs the image once against the backup volume. the output goes to a log file and into
# RUN_OUTPUT, the exit code is the return value
runBackup() {
  local _NAME=${1}
  local _CODE=0

  shift

  RUN_LOG="${LOG_DIR}/${_NAME}.log"

  docker run --rm --network "${NETWORK}" --label "${LABEL}" \
    -v "${BACKUP_VOLUME}:/backup" "${@}" "${IMAGE}" > "${RUN_LOG}" 2>&1 || _CODE=$?

  RUN_OUTPUT="$(cat "${RUN_LOG}")"

  return ${_CODE}
}

# looks into the backup volume with a throwaway container, so the test never needs a
# host path and the volume stays the only place a backup exists
inBackupVolume() {
  docker run --rm --label "${LABEL}" -v "${BACKUP_VOLUME}:/backup" \
    "${ALPINE_IMAGE}" sh -c "${1}" 2>&1
}

# Emptied from the inside instead of removed and recreated: 'docker volume rm' fails
# while a container that used the volume still exists, and a '--rm' container is cleaned
# up by the daemon a moment after it exits - so right after a backup run that moment may
# not have come yet. The failure is silent, and a reset that quietly does nothing leaves
# the files of the previous test behind and makes the next assertion lie about them.
resetBackupVolume() {
  docker volume create --label "${LABEL}" "${BACKUP_VOLUME}" > /dev/null 2>&1
  inBackupVolume 'find /backup -mindepth 1 -delete' > /dev/null 2>&1
}

# A database is only usable once its init scripts have run - the container being up says
# nothing about that, so every group waits for a command that needs a working server.
#
# The probe has to go over TCP ('-h 127.0.0.1'), not over the local socket: while the
# official images initialise, they run a temporary server that listens on the socket only
# ('--skip-networking' for mysql/mariadb, an empty 'listen_addresses' for postgres). A
# socket probe goes green there, and the backup container - which connects over the
# network - then gets 'Can't connect to server'.
waitFor() {
  local _NAME=${1}
  local _COMMAND=${2}
  local _TRIES=${3:-90}
  local _I=0

  while [ ${_I} -lt ${_TRIES} ]; do
    if docker exec "${_NAME}" sh -c "${_COMMAND}" > /dev/null 2>&1; then
      return 0
    fi

    if [ -z "$(docker ps -q --filter "name=^/${_NAME}$")" ]; then
      break
    fi

    sleep 1
    _I=$((_I + 1))
  done

  # a group that gives up here only reports a skip, and a skip without a reason is the
  # kind of thing that gets ignored until it hides a real failure
  docker logs "${_NAME}" > "${LOG_DIR}/${_NAME}.log" 2>&1
  info "'${_NAME}' was not ready after ${_I}s, see ${LOG_DIR}/${_NAME}.log"

  return 1
}

containerExists() {
  [ ! -z "$(docker ps -a -q --filter "name=^/${1}$")" ]
}

# The value is handed to 'sh' as an argument, not pasted into the script it runs: the
# test password holds a double quote, a backslash and a '#', and any of those would be
# read as syntax if the content became part of the command line.
writeSecretFile() {
  docker run --rm --label "${LABEL}" -v "${SECRET_VOLUME}:/secrets" "${ALPINE_IMAGE}" \
    sh -c 'printf "%s" "$2" > "/secrets/$1"' sh "${1}" "${2}" > /dev/null 2>&1
}

# same, with the trailing newline an editor leaves behind - 'readSecretFile' has to strip
# it, otherwise the password carries a '\n' and the login fails
writeSecretFileWithNewline() {
  docker run --rm --label "${LABEL}" -v "${SECRET_VOLUME}:/secrets" "${ALPINE_IMAGE}" \
    sh -c 'printf "%s\n" "$2" > "/secrets/$1"' sh "${1}" "${2}" > /dev/null 2>&1
}

resetSecretVolume() {
  docker volume create --label "${LABEL}" "${SECRET_VOLUME}" > /dev/null 2>&1
  docker run --rm --label "${LABEL}" -v "${SECRET_VOLUME}:/secrets" "${ALPINE_IMAGE}" \
    sh -c 'find /secrets -mindepth 1 -delete' > /dev/null 2>&1
}

###############################################################################
#### Group: unit - everything that is rejected before a database is touched
###############################################################################

group_unit() {
  section "unit - configuration is rejected before anything is written"

  local _CODE=0

  runBackup "unit-cron-newline" \
    -e "CRON_SCHEDULE=$(printf '@daily\n* * * * * touch /tmp/pwned')" || _CODE=$?
  assertFails "CRON_SCHEDULE over two lines is rejected" "${_CODE}" \
    && assertContains "  and says why" "${RUN_OUTPUT}" "must be a single line"

  _CODE=0
  runBackup "unit-cron-keyword" -e "CRON_SCHEDULE=@5min" || _CODE=$?
  assertFails "CRON_SCHEDULE with an unknown keyword is rejected" "${_CODE}" \
    && assertContains "  and names the ones that work" "${RUN_OUTPUT}" "'@midnight'"

  _CODE=0
  runBackup "unit-cron-fields" -e "CRON_SCHEDULE=0 3 * *" || _CODE=$?
  assertFails "CRON_SCHEDULE with four fields is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "must have 5 fields"

  _CODE=0
  runBackup "unit-cron-char" -e "CRON_SCHEDULE=0 3 * * * %evil" || _CODE=$?
  assertFails "CRON_SCHEDULE with a stray character is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "'CRON_SCHEDULE' must only contain"

  _CODE=0
  runBackup "unit-filename-traversal" \
    -e BACKUP=mysql -e "MYSQLDUMP_FILENAME=../../etc/cron.d/evil" || _CODE=$?
  assertFails "a file name with a path is rejected" "${_CODE}" \
    && assertContains "  and says why" "${RUN_OUTPUT}" "must only contain"

  _CODE=0
  runBackup "unit-filename-glob" -e BACKUP=mysql -e "MYSQLDUMP_FILENAME=*" || _CODE=$?
  assertFails "a file name that is a glob is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "'MYSQLDUMP_FILENAME' must only contain"

  _CODE=0
  runBackup "unit-filename-space" -e BACKUP=mariadb -e "MARIADBDUMP_FILENAME=bad name" || _CODE=$?
  assertFails "a file name with a space is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "'MARIADBDUMP_FILENAME' must only contain"

  _CODE=0
  runBackup "unit-filename-quote" -e BACKUP=sqlite -e "SQLITE_FILENAME=x'y" || _CODE=$?
  assertFails "a file name with a quote is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "'SQLITE_FILENAME' must only contain"

  _CODE=0
  runBackup "unit-umask" -e BACKUP=mariadb -e "BACKUP_UMASK=888" || _CODE=$?
  assertFails "BACKUP_UMASK that is not octal is rejected" "${_CODE}" \
    && assertContains "  and says why" "${RUN_OUTPUT}" "octal"

  _CODE=0
  runBackup "unit-backup-type" -e "BACKUP=nope" || _CODE=$?
  assertFails "an unknown BACKUP type is rejected" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "not supported"

  # the counter test: a name that is fine has to get past the check and fail later, on
  # the database - otherwise the pattern is simply too strict
  _CODE=0
  runBackup "unit-filename-ok" \
    -e BACKUP=mysql -e "MYSQLDUMP_FILENAME=back-up_1.v2" -e MYSQL_HOST=nowhere \
    -e MYSQL_USERNAME=u -e MYSQL_PASSWORD=p || _CODE=$?
  assertNotContains "a valid file name passes the check" "${RUN_OUTPUT}" "must only contain"
  # without this the case above proves nothing: an output that is empty because the
  # container never started holds no 'must only contain' either
  assertContains "  and the run gets as far as the database" "${RUN_OUTPUT}" "MySQL dump starting"
}

###############################################################################
#### Group: mariadb
###############################################################################

startMariadb() {
  if containerExists "${MARIADB_HOST}"; then
    return 0
  fi

  pullImage "${MARIADB_IMAGE}"
  info "starting ${MARIADB_IMAGE}"
  dockerRun "${MARIADB_HOST}" -e "MARIADB_ROOT_PASSWORD=${ROOT_PASSWORD}" "${MARIADB_IMAGE}"

  if ! waitFor "${MARIADB_HOST}" "mariadb -h 127.0.0.1 -uroot -p'${ROOT_PASSWORD}' -e 'SELECT 1'" 180; then
    return 1
  fi

  docker exec -i "${MARIADB_HOST}" mariadb -uroot -p"${ROOT_PASSWORD}" <<SQL > /dev/null 2>&1
CREATE DATABASE IF NOT EXISTS itestdb;
USE itestdb;
CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(64));
INSERT INTO items VALUES (1, '${MARKER}'), (2, 'he said "hi"');
CREATE USER IF NOT EXISTS 'itest'@'%' IDENTIFIED BY 'pa"ss\\\\wo rd#1';
GRANT ALL PRIVILEGES ON *.* TO 'itest'@'%';
FLUSH PRIVILEGES;
SQL
}

runMariadbBackup() {
  local _NAME=${1}

  shift

  runBackup "${_NAME}" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e "MARIADB_PASSWORD=${DB_PASSWORD}" \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest \
    "${@}"
}

group_mariadb() {
  section "mariadb"

  if ! startMariadb; then
    skip "mariadb dump" "the database did not come up"
    return 0
  fi

  resetBackupVolume

  local _CODE=0
  runMariadbBackup "mariadb-dump" || _CODE=$?

  assertEquals "the dump succeeds with a password holding a quote, backslash and space" "0" "${_CODE}"

  local _FILES="$(inBackupVolume 'ls /backup')"
  assertContains "the dump is named '<timestamp>.itest.sql'" "${_FILES}" ".itest.sql"

  local _CONTENT="$(inBackupVolume 'cat /backup/*.itest.sql')"
  assertContains "the dump holds the seeded row" "${_CONTENT}" "${MARKER}"
  assertContains "the dump holds the CREATE TABLE" "${_CONTENT}" "CREATE TABLE"

  local _MODE="$(inBackupVolume 'stat -c %a /backup/*.itest.sql')"
  assertEquals "the dump is created with mode 0640" "640" "${_MODE}"
}

###############################################################################
#### Group: mysql
###############################################################################

group_mysql() {
  section "mysql"

  if ! containerExists "${MYSQL_HOST}"; then
    pullImage "${MYSQL_IMAGE}"
    info "starting ${MYSQL_IMAGE}"
    dockerRun "${MYSQL_HOST}" -e "MYSQL_ROOT_PASSWORD=${ROOT_PASSWORD}" "${MYSQL_IMAGE}"

    if ! waitFor "${MYSQL_HOST}" "mysql -h 127.0.0.1 -uroot -p'${ROOT_PASSWORD}' -e 'SELECT 1'" 180; then
      skip "mysql dump" "the database did not come up"
      return 0
    fi

    docker exec -i "${MYSQL_HOST}" mysql -uroot -p"${ROOT_PASSWORD}" <<SQL > /dev/null 2>&1
CREATE DATABASE IF NOT EXISTS itestdb;
USE itestdb;
CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(64));
INSERT INTO items VALUES (1, '${MARKER}');
CREATE USER IF NOT EXISTS 'itest'@'%' IDENTIFIED BY 'pa"ss\\\\wo rd#1';
GRANT ALL PRIVILEGES ON *.* TO 'itest'@'%';
FLUSH PRIVILEGES;
SQL
  fi

  resetBackupVolume

  local _CODE=0

  # 8.4 and newer verifies the certificate the server creates on first start, which is
  # self signed - the same workaround the README documents. It has to be the mariadb
  # spelling of the option: on alpine '/usr/bin/mysqldump' is a symlink to 'mariadb-dump'
  # and that client does not know '--ssl-mode'
  runBackup "mysql-dump" \
    -e BACKUP=mysql \
    -e "MYSQL_HOST=${MYSQL_HOST}" \
    -e MYSQL_USERNAME=itest \
    -e "MYSQL_PASSWORD=${DB_PASSWORD}" \
    -e MYSQLDUMP_DATABASES=itestdb \
    -e MYSQLDUMP_FILENAME=itest \
    -e "MYSQLDUMP_ADD_OPTIONS=--ssl-verify-server-cert=0" || _CODE=$?

  assertEquals "the dump succeeds" "0" "${_CODE}"
  assertContains "the dump holds the seeded row" "$(inBackupVolume 'cat /backup/*.itest.sql')" "${MARKER}"
}

###############################################################################
#### Group: pgsql
###############################################################################

startPgsql() {
  if containerExists "${PGSQL_HOST}"; then
    return 0
  fi

  pullImage "${PGSQL_IMAGE}"
  info "starting ${PGSQL_IMAGE}"
  dockerRun "${PGSQL_HOST}" -e "POSTGRES_PASSWORD=${DB_PASSWORD}" "${PGSQL_IMAGE}"

  # generous, because a database that is initialising while another group's server is
  # still starting up needs noticeably longer than one that comes up on its own
  if ! waitFor "${PGSQL_HOST}" "pg_isready -h 127.0.0.1 -U postgres" 180; then
    return 1
  fi

  docker exec -i "${PGSQL_HOST}" psql -U postgres -v ON_ERROR_STOP=1 <<SQL > /dev/null 2>&1
CREATE DATABASE itestdb1;
CREATE DATABASE itestdb2;
SQL

  docker exec -i "${PGSQL_HOST}" psql -U postgres -d itestdb1 -v ON_ERROR_STOP=1 <<SQL > /dev/null 2>&1
CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(64));
INSERT INTO items VALUES (1, '${MARKER}');
SQL
}

group_pgsql() {
  section "pgsql"

  if ! startPgsql; then
    skip "pgsql dump" "the database did not come up"
    return 0
  fi

  resetBackupVolume

  local _CODE=0
  runBackup "pgsql-dump" \
    -e BACKUP=pgsql \
    -e "PGSQL_HOST=${PGSQL_HOST}" \
    -e PGSQL_USERNAME=postgres \
    -e "PGSQL_PASSWORD=${DB_PASSWORD}" \
    -e "PGSQL_DATABASES=itestdb1 itestdb2" \
    -e PGSQL_FILENAME=itest || _CODE=$?

  assertEquals "the dump of a database list succeeds" "0" "${_CODE}"

  local _CONTENT="$(inBackupVolume 'cat /backup/*.itest.sql')"
  assertContains "the dump holds the seeded row" "${_CONTENT}" "${MARKER}"
  assertContains "the first database gets its banner" "${_CONTENT}" "PostgreSQL backup database: itestdb1"
  assertContains "the second one is appended to the same file" "${_CONTENT}" "PostgreSQL backup database: itestdb2"

  resetBackupVolume

  _CODE=0
  runBackup "pgsql-dumpall" \
    -e BACKUP=pgsql \
    -e "PGSQL_HOST=${PGSQL_HOST}" \
    -e PGSQL_USERNAME=postgres \
    -e "PGSQL_PASSWORD=${DB_PASSWORD}" \
    -e "PGSQL_DATABASES=--all-databases" \
    -e PGSQL_FILENAME=itest || _CODE=$?

  assertEquals "'--all-databases' goes through pg_dumpall" "0" "${_CODE}"
  assertContains "and holds the seeded row too" "$(inBackupVolume 'cat /backup/*.itest.sql')" "${MARKER}"

  ## the second client version #################################################
  # the image carries two of them and picks the binary by path, so a broken PGSQL_VERSION
  # is a 'file not found' at dump time and nothing earlier
  resetBackupVolume

  _CODE=0
  runBackup "pgsql-version-18" \
    -e BACKUP=pgsql \
    -e "PGSQL_HOST=${PGSQL_HOST}" \
    -e PGSQL_USERNAME=postgres \
    -e "PGSQL_PASSWORD=${DB_PASSWORD}" \
    -e PGSQL_DATABASES=itestdb1 \
    -e PGSQL_FILENAME=itest \
    -e PGSQL_VERSION=18 || _CODE=$?

  assertEquals "the version 18 client is present and used" "0" "${_CODE}"
  assertContains "and dumps the seeded row" "$(inBackupVolume 'cat /backup/*.itest.sql')" "${MARKER}"

  _CODE=0
  runBackup "pgsql-version-bad" \
    -e BACKUP=pgsql \
    -e "PGSQL_HOST=${PGSQL_HOST}" \
    -e PGSQL_USERNAME=postgres \
    -e "PGSQL_PASSWORD=${DB_PASSWORD}" \
    -e PGSQL_DATABASES=itestdb1 \
    -e PGSQL_FILENAME=itest \
    -e PGSQL_VERSION=99 || _CODE=$?

  assertFails "an unavailable client version fails the run" "${_CODE}" \
    && assertContains "  because that binary is not there" "${RUN_OUTPUT}" "postgresql99/pg_dump"

  _CODE=0
  runBackup "pgsql-port" \
    -e BACKUP=pgsql \
    -e "PGSQL_HOST=${PGSQL_HOST}" \
    -e PGSQL_PORT=9999 \
    -e PGSQL_USERNAME=postgres \
    -e "PGSQL_PASSWORD=${DB_PASSWORD}" \
    -e PGSQL_DATABASES=itestdb1 \
    -e PGSQL_FILENAME=itest || _CODE=$?

  assertFails "PGSQL_PORT is really used" "${_CODE}" \
    && assertContains "  and it is the port that was refused" "${RUN_OUTPUT}" "port 9999"
}

###############################################################################
#### Group: sqlite
###############################################################################

group_sqlite() {
  section "sqlite"

  local _DB_VOLUME="${PREFIX}-sqlite"

  docker volume rm -f "${_DB_VOLUME}" > /dev/null 2>&1
  docker volume create --label "${LABEL}" "${_DB_VOLUME}" > /dev/null

  # built with the image itself, it is the one that brings sqlite3 along
  docker run --rm --label "${LABEL}" -v "${_DB_VOLUME}:/data" "${IMAGE}" \
    sqlite3 /data/app.db "CREATE TABLE items (id INT, name TEXT); INSERT INTO items VALUES (1, '${MARKER}');" > /dev/null 2>&1
  docker run --rm --label "${LABEL}" -v "${_DB_VOLUME}:/data" "${IMAGE}" \
    sqlite3 /data/second.db "CREATE TABLE more (id INT);" > /dev/null 2>&1

  resetBackupVolume

  local _CODE=0
  runBackup "sqlite-backup" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/app.db \
    -e SQLITE_MODE=backup \
    -e SQLITE_FILENAME=itest || _CODE=$?

  assertEquals "the online backup succeeds" "0" "${_CODE}"
  assertContains "and writes a '.db'" "$(inBackupVolume 'ls /backup')" ".itest.db"

  local _READ="$(docker run --rm --label "${LABEL}" -v "${BACKUP_VOLUME}:/backup" "${IMAGE}" \
    sh -c 'sqlite3 "$(ls /backup/*.itest.db)" "SELECT name FROM items;"' 2>&1)"
  assertContains "the copy opens and holds the row" "${_READ}" "${MARKER}"

  resetBackupVolume

  _CODE=0
  runBackup "sqlite-dump" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e "SQLITE_DATABASE=/data/app.db /data/second.db" \
    -e SQLITE_MODE=dump \
    -e SQLITE_FILENAME=itest || _CODE=$?

  assertEquals "the dump of two databases succeeds" "0" "${_CODE}"

  local _CONTENT="$(inBackupVolume 'cat /backup/*.itest.sql')"
  assertContains "it holds the first database" "${_CONTENT}" "${MARKER}"
  assertContains "and the banner of the second" "${_CONTENT}" "SQLite backup database: /data/second.db"

  _CODE=0
  runBackup "sqlite-backup-two" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e "SQLITE_DATABASE=/data/app.db /data/second.db" \
    -e SQLITE_MODE=backup \
    -e SQLITE_FILENAME=itest || _CODE=$?

  assertFails "two databases in backup mode are refused" "${_CODE}" \
    && assertContains "  and points at dump mode" "${RUN_OUTPUT}" "handles exactly one database"

  _CODE=0
  runBackup "sqlite-missing" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/nothing.db \
    -e SQLITE_FILENAME=itest || _CODE=$?

  assertFails "a database that does not exist is refused" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "does not exist or is not a file"

  ## the size report ##########################################################
  resetBackupVolume

  _CODE=0
  runBackup "sqlite-report-size" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/app.db \
    -e SQLITE_FILENAME=itest \
    -e SQLITE_REPORT_SIZE=true || _CODE=$?

  assertEquals "a run with SQLITE_REPORT_SIZE succeeds" "0" "${_CODE}"
  assertContains "and reports both sizes" "${RUN_OUTPUT}" "bytes on disk"
  assertEquals "the VACUUM file is cleaned up" "0" \
    "$(inBackupVolume 'ls -A /backup | grep -c sqlite-vacuum')"

  ## the integrity check ######################################################
  # A broken backup has to fail the run instead of being stored. The script goes in over
  # stdin so the SQL can use single quotes: sqlite reads a double quoted value as an
  # identifier, so '"x"' is not a string but a column that does not exist, and the insert
  # fails instead of filling the table.
  #
  # Scribbled over page 2, where the rows are. Page 1 holds the schema and enough free
  # space that random bytes in it go unnoticed by 'PRAGMA integrity_check' - which is
  # what made an earlier version of this test pass a database that was still intact.
  docker run --rm -i --label "${LABEL}" -v "${_DB_VOLUME}:/data" "${IMAGE}" sh -s > /dev/null 2>&1 <<'SEED'
rm -f /data/broken.db
sqlite3 /data/broken.db "CREATE TABLE t (a TEXT);"
for i in $(seq 1 400); do
  echo "INSERT INTO t VALUES ('padding-row-$i-aaaaaaaaaaaaaaaaaaaaaaaaaaaa');"
done | sqlite3 /data/broken.db
dd if=/dev/urandom of=/data/broken.db bs=1 seek=4096 count=400 conv=notrunc
SEED

  resetBackupVolume

  _CODE=0
  runBackup "sqlite-integrity" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/broken.db \
    -e SQLITE_MODE=dump \
    -e SQLITE_FILENAME=itest \
    -e SQLITE_INTEGRITY_CHECK=true || _CODE=$?

  assertFails "a corrupted database fails the run" "${_CODE}" \
    && assertContains "  because the integrity check caught it" "${RUN_OUTPUT}" "integrity check failed"
  assertEquals "and leaves no dump behind" "0" \
    "$(inBackupVolume 'ls /backup/*.itest.sql 2>/dev/null | wc -l')"

  ## an optional report must not take a finished backup with it ###############
  # 'VACUUM INTO' of the size report runs against the source, and on a malformed database
  # it fails. At that point the backup file is already complete, so it has to survive -
  # an informational diagnostic is not allowed to delete a finished backup.
  resetBackupVolume

  _CODE=0
  runBackup "sqlite-report-keeps-backup" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/broken.db \
    -e SQLITE_MODE=backup \
    -e SQLITE_FILENAME=itest \
    -e SQLITE_INTEGRITY_CHECK=false \
    -e SQLITE_REPORT_SIZE=true || _CODE=$?

  assertContains "a failing size report keeps the finished backup" \
    "$(inBackupVolume 'ls /backup')" ".itest.db"

  ## a quote in the path the sqlite3 dot command is built from #################
  # 'SQLITE_FILENAME' is validated, but the directory in front of it is not - and with
  # compression on, that directory is 'STAGING_DIR'. This is the case the escaping in
  # 'sqlite.sh' exists for; without it the dot command argument ends at the quote.
  resetBackupVolume

  _CODE=0
  runBackup "sqlite-quoted-staging" -v "${_DB_VOLUME}:/data" \
    -e BACKUP=sqlite \
    -e SQLITE_DATABASE=/data/app.db \
    -e SQLITE_FILENAME=itest \
    -e "STAGING_DIR=/tmp/o'brien \"quoted\"" \
    -e COMPRESS_ENABLE=true || _CODE=$?

  assertEquals "a quote in STAGING_DIR does not break the backup" "0" "${_CODE}"
  assertContains "and the archive is written" "$(inBackupVolume 'ls /backup')" ".itest.db.7z"
}

###############################################################################
#### Group: secrets - every credential can come from a file instead
###############################################################################

group_secrets() {
  section "secrets - credentials from files"

  if ! startMariadb; then
    skip "secrets" "the database did not come up"
    return 0
  fi

  resetSecretVolume

  writeSecretFile "db-password" "${DB_PASSWORD}"
  writeSecretFileWithNewline "db-password-nl" "${DB_PASSWORD}"
  writeSecretFile "archive-password" 'arch"ive pw#2'
  writeSecretFile "empty" ""

  local _CODE=0

  ## the happy path #########################################################
  resetBackupVolume

  _CODE=0
  runBackup "secrets-password-file" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/db-password \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest || _CODE=$?

  assertEquals "the database password is read from a file" "0" "${_CODE}"
  assertContains "and the run says where it came from" "${RUN_OUTPUT}" "MARIADB_PASSWORD_FILE"
  assertContains "the dump holds the seeded row" "$(inBackupVolume 'cat /backup/*.itest.sql')" "${MARKER}"

  resetBackupVolume

  _CODE=0
  runBackup "secrets-password-file-newline" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/db-password-nl \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest || _CODE=$?

  assertEquals "a trailing newline in the file is stripped" "0" "${_CODE}"

  ## the error paths ########################################################
  _CODE=0
  runBackup "secrets-both" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e "MARIADB_PASSWORD=${DB_PASSWORD}" \
    -e MARIADB_PASSWORD_FILE=/secrets/db-password \
    -e MARIADBDUMP_FILENAME=itest || _CODE=$?

  assertFails "setting the variable and its _FILE at once is refused" "${_CODE}" \
    && assertContains "  and says why" "${RUN_OUTPUT}" "not both"

  _CODE=0
  runBackup "secrets-missing" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/does-not-exist \
    -e MARIADBDUMP_FILENAME=itest || _CODE=$?

  assertFails "a missing secret file is refused" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "does not exist"

  _CODE=0
  runBackup "secrets-empty" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/empty \
    -e MARIADBDUMP_FILENAME=itest || _CODE=$?

  assertFails "an empty secret file is refused" "${_CODE}" \
    && assertContains "  and for that reason" "${RUN_OUTPUT}" "is empty"

  ## the other credentials ##################################################
  resetBackupVolume

  _CODE=0
  runBackup "secrets-archive-password" -v "${SECRET_VOLUME}:/secrets" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/db-password \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest \
    -e COMPRESS_ENABLE=true \
    -e COMPRESS_ENCRYPTION_PASSWORD_FILE=/secrets/archive-password || _CODE=$?

  assertEquals "the archive password is read from a file" "0" "${_CODE}"

  local _OPENS="$(docker run --rm --label "${LABEL}" -v "${BACKUP_VOLUME}:/backup" "${IMAGE}" \
    sh -c '7z t -p"arch\"ive pw#2" /backup/*.7z > /dev/null 2>&1 && echo ok || echo broken')"
  assertEquals "and the archive opens with exactly that password" "ok" "${_OPENS}"

  if startWebhook; then
    writeSecretFile "webhook-url" "http://${WEBHOOK_HOST}:8080/cgi-bin/hook"
    resetBackupVolume

    _CODE=0
    runBackup "secrets-webhook-url" -v "${SECRET_VOLUME}:/secrets" \
      -e BACKUP=mariadb \
      -e "MARIADB_HOST=${MARIADB_HOST}" \
      -e MARIADB_USERNAME=itest \
      -e MARIADB_PASSWORD_FILE=/secrets/db-password \
      -e MARIADBDUMP_DATABASES=itestdb \
      -e MARIADBDUMP_FILENAME=itest \
      -e WEBHOOK_SUCCESS_URL_FILE=/secrets/webhook-url || _CODE=$?

    assertEquals "the webhook URL is read from a file" "0" "${_CODE}"
    assertContains "and the receiver is called" "$(webhookLog)" "METHOD=GET"
  else
    skip "webhook URL from a file" "the receiver did not come up"
  fi

  ## the reason the resolving lives in the stage scripts #####################
  # 'entrypoint.sh' snapshots the environment for cron before the first backup runs. If
  # the secret were resolved there, the password would sit in '/tmp/dbbackup.env' in
  # clear text for the life of the container. Only the path may end up in it.
  local _NAME="${PREFIX}-secrets-cron"

  docker rm -f "${_NAME}" > /dev/null 2>&1

  dockerRun "${_NAME}" \
    -v "${SECRET_VOLUME}:/secrets" \
    -v "${BACKUP_VOLUME}:/backup" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e MARIADB_PASSWORD_FILE=/secrets/db-password \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest \
    -e "CRON_SCHEDULE=0 3 * * *" \
    "${IMAGE}"

  if waitFor "${_NAME}" "test -f /tmp/dbbackup.env" 60; then
    local _SNAPSHOT="$(docker exec "${_NAME}" cat /tmp/dbbackup.env 2>&1)"

    assertNotContains "the cron snapshot holds no password" "${_SNAPSHOT}" "${DB_PASSWORD}"
    assertContains "only the path to the secret file" "${_SNAPSHOT}" "/secrets/db-password"
    assertEquals "and the snapshot is mode 0600" "600" \
      "$(docker exec "${_NAME}" stat -c %a /tmp/dbbackup.env 2>&1)"
  else
    skip "the cron snapshot holds no password" "the container did not come up"
  fi

  docker rm -f "${_NAME}" > /dev/null 2>&1
}

###############################################################################
#### Group: features - compress, encrypt, retention, umask, webhooks
###############################################################################

startWebhook() {
  if containerExists "${WEBHOOK_HOST}"; then
    docker exec "${WEBHOOK_HOST}" sh -c ': > /tmp/hook.log' > /dev/null 2>&1
    return 0
  fi

  pullImage "${BUSYBOX_IMAGE}"
  info "starting the webhook receiver"

  # busybox httpd with one CGI script - the request including the POST body ends up in a
  # file the test can read. It runs on the busybox image and not on alpine, whose busybox
  # is built without the httpd applet
  dockerRun "${WEBHOOK_HOST}" "${BUSYBOX_IMAGE}" sh -c '
    mkdir -p /www/cgi-bin
    cat > /www/cgi-bin/hook <<EOF
#!/bin/sh
{ echo "METHOD=\$REQUEST_METHOD"; [ "\$REQUEST_METHOD" = POST ] && head -c "\${CONTENT_LENGTH:-0}"; echo; } >> /tmp/hook.log
printf "Content-Type: text/plain\r\n\r\nok\r\n"
EOF
    chmod +x /www/cgi-bin/hook
    : > /tmp/hook.log
    httpd -f -p 8080 -h /www'

  waitFor "${WEBHOOK_HOST}" "test -f /tmp/hook.log"
}

webhookLog() {
  docker exec "${WEBHOOK_HOST}" cat /tmp/hook.log 2>&1
}

group_features() {
  section "features - compress, encrypt, retention, umask, webhooks"

  if ! startMariadb; then
    skip "features" "the database did not come up"
    return 0
  fi

  local _CODE=0

  ## compression ##############################################################
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-compress" -e COMPRESS_ENABLE=true || _CODE=$?

  assertEquals "a compressed run succeeds" "0" "${_CODE}"

  local _FILES="$(inBackupVolume 'ls /backup')"
  assertContains "the archive is in the backup target" "${_FILES}" ".itest.sql.7z"
  assertEquals "and the raw dump is not" "0" "$(inBackupVolume 'ls /backup/*.sql 2>/dev/null | wc -l')"
  assertEquals "the archive is created with mode 0640" "640" "$(inBackupVolume 'stat -c %a /backup/*.7z')"

  ## encryption ###############################################################
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-encrypt" \
    -e COMPRESS_ENABLE=true \
    -e "COMPRESS_ENCRYPTION_PASSWORD=arch\"ive pw#2" || _CODE=$?

  assertEquals "an encrypted run succeeds" "0" "${_CODE}"

  local _TEST_OK="$(docker run --rm --label "${LABEL}" -v "${BACKUP_VOLUME}:/backup" "${IMAGE}" \
    sh -c '7z t -p"arch\"ive pw#2" /backup/*.7z > /dev/null 2>&1 && echo ok || echo broken')"
  assertEquals "the archive opens with the right password" "ok" "${_TEST_OK}"

  local _TEST_BAD="$(docker run --rm --label "${LABEL}" -v "${BACKUP_VOLUME}:/backup" "${IMAGE}" \
    sh -c '7z t -pwrong /backup/*.7z > /dev/null 2>&1 && echo ok || echo broken')"
  assertEquals "and not with a wrong one" "broken" "${_TEST_BAD}"

  ## umask ####################################################################
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-umask" -e BACKUP_UMASK=022 || _CODE=$?

  assertEquals "a run with BACKUP_UMASK=022 succeeds" "0" "${_CODE}"
  assertEquals "and gives the old mode 0644 back" "644" "$(inBackupVolume 'stat -c %a /backup/*.itest.sql')"

  ## retention ################################################################
  resetBackupVolume

  # three older backups, one of them the empty leftover of a failed dump, plus a file
  # that belongs to somebody else and has to stay
  inBackupVolume '
    echo old > /backup/20200101-000000.itest.sql
    echo old > /backup/20200102-000000.itest.sql
    : > /backup/20200103-000000.itest.sql
    echo mine > /backup/please-keep.txt' > /dev/null

  _CODE=0
  runMariadbBackup "features-retention" -e RETENTION_KEEP_LAST=2 || _CODE=$?

  assertEquals "a run with retention succeeds" "0" "${_CODE}"

  _FILES="$(inBackupVolume 'ls /backup')"
  assertContains "the backup of this run stays" "${_FILES}" ".itest.sql"
  assertContains "the newest old one stays" "${_FILES}" "20200102-000000.itest.sql"
  assertNotContains "the one over the limit is gone" "${_FILES}" "20200101-000000.itest.sql"
  assertNotContains "the empty leftover is gone" "${_FILES}" "20200103-000000.itest.sql"
  assertContains "a foreign file is not touched" "${_FILES}" "please-keep.txt"

  ## retention by age #########################################################
  # the age comes from the mtime, not from the name - so the mtime is what gets faked
  resetBackupVolume

  inBackupVolume '
    echo old > /backup/20200101-000000.itest.sql
    touch -t 202001010000 /backup/20200101-000000.itest.sql
    echo young > /backup/20990101-000000.itest.sql' > /dev/null

  _CODE=0
  runMariadbBackup "features-retention-days" -e RETENTION_KEEP_DAYS=1 || _CODE=$?

  assertEquals "a run with RETENTION_KEEP_DAYS succeeds" "0" "${_CODE}"

  _FILES="$(inBackupVolume 'ls /backup')"
  assertNotContains "a backup older than the limit is gone" "${_FILES}" "20200101-000000.itest.sql"
  assertContains "a younger one stays" "${_FILES}" "20990101-000000.itest.sql"
  assertContains "and the backup of this run stays" "${_FILES}" ".itest.sql"

  ## retention: the two rules are a union, not an intersection ################
  # This is the one that costs data when it breaks: after a longer outage every backup is
  # older than 'RETENTION_KEEP_DAYS', and a rule that only looked at age would delete the
  # last working backups. 'RETENTION_KEEP_LAST' is the floor underneath it.
  resetBackupVolume

  inBackupVolume '
    for d in 20200101 20200102 20200103; do
      echo old > /backup/${d}-000000.itest.sql
      touch -t 202001010000 /backup/${d}-000000.itest.sql
    done' > /dev/null

  _CODE=0
  runMariadbBackup "features-retention-union" \
    -e RETENTION_KEEP_DAYS=1 -e RETENTION_KEEP_LAST=2 || _CODE=$?

  assertEquals "a run with both retention rules succeeds" "0" "${_CODE}"

  _FILES="$(inBackupVolume 'ls /backup')"
  assertContains "KEEP_LAST rescues a backup that is too old" "${_FILES}" "20200103-000000.itest.sql"
  assertNotContains "the one past both rules is gone" "${_FILES}" "20200102-000000.itest.sql"
  assertNotContains "and the oldest one too" "${_FILES}" "20200101-000000.itest.sql"

  ## dump options can be replaced #############################################
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-dump-options" -e "MARIADBDUMP_OPTIONS=--no-data" || _CODE=$?

  assertEquals "a run with replaced dump options succeeds" "0" "${_CODE}"

  local _SCHEMA="$(inBackupVolume 'cat /backup/*.itest.sql')"
  assertContains "the dump still holds the schema" "${_SCHEMA}" "CREATE TABLE"
  assertNotContains "but no data, as '--no-data' asks" "${_SCHEMA}" "${MARKER}"

  ## a staging directory of its own ############################################
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-staging-dir" \
    -e COMPRESS_ENABLE=true -e STAGING_DIR=/tmp/somewhere-else || _CODE=$?

  assertEquals "a run with a custom STAGING_DIR succeeds" "0" "${_CODE}"

  _FILES="$(inBackupVolume 'ls /backup')"
  assertContains "the archive reaches the target" "${_FILES}" ".itest.sql.7z"
  assertEquals "and no raw dump is left in it" "0" "$(inBackupVolume 'ls /backup/*.sql 2>/dev/null | wc -l')"

  ## a port that is not listening ##############################################
  _CODE=0
  runMariadbBackup "features-port" -e MARIADB_PORT=9999 || _CODE=$?

  assertFails "MARIADB_PORT is really used" "${_CODE}" \
    && assertContains "  because the connection was refused" "${RUN_OUTPUT}" "Can't connect to server"

  ## webhooks #################################################################
  if ! startWebhook; then
    skip "webhooks" "the receiver did not come up"
    return 0
  fi

  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-webhook-get" \
    -e "WEBHOOK_SUCCESS_URL=http://${WEBHOOK_HOST}:8080/cgi-bin/hook" || _CODE=$?

  assertEquals "a run with a GET webhook succeeds" "0" "${_CODE}"
  assertContains "the receiver saw a GET" "$(webhookLog)" "METHOD=GET"

  startWebhook
  resetBackupVolume

  _CODE=0
  runMariadbBackup "features-webhook-post" \
    -e WEBHOOK_METHOD=POST \
    -e "WEBHOOK_SUCCESS_URL=http://${WEBHOOK_HOST}:8080/cgi-bin/hook" || _CODE=$?

  assertEquals "a run with a POST webhook succeeds" "0" "${_CODE}"

  local _BODY="$(webhookLog)"
  assertContains "the receiver saw a POST" "${_BODY}" "METHOD=POST"
  assertContains "the body reports the success" "${_BODY}" '"status":"success"'
  assertContains "the body names the backup type" "${_BODY}" '"backup":"mariadb"'
  assertNotContains "the body holds no database password" "${_BODY}" "${DB_PASSWORD}"
  assertNotContains "and no password field at all" "${_BODY}" "password"

  startWebhook
  resetBackupVolume

  _CODE=0
  # the carriage return is deliberate: that is how a host arrives from a '.env' file or a
  # CI variable with CRLF line endings, and it has to survive into the webhook body as an
  # escape instead of breaking the JSON
  runBackup "features-webhook-failure" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=$(printf 'nowhere-at-all\r')" \
    -e MARIADB_USERNAME=itest \
    -e "MARIADB_PASSWORD=${DB_PASSWORD}" \
    -e MARIADBDUMP_FILENAME=itest \
    -e WEBHOOK_METHOD=POST \
    -e "WEBHOOK_FAILURE_URL=http://${WEBHOOK_HOST}:8080/cgi-bin/hook" || _CODE=$?

  assertFails "a run against an unreachable host fails" "${_CODE}" \
    && assertContains "  because the host could not be resolved" "${RUN_OUTPUT}" "Unknown server host"

  _BODY="$(webhookLog)"
  assertContains "the failure webhook is called" "${_BODY}" '"status":"failure"'

  # The host went in with a carriage return, the way it arrives from a '.env' file or a
  # CI variable with CRLF line endings. Raw control characters are not allowed inside a
  # JSON string, so an unescaped one would hand the receiver a body it has to reject -
  # losing exactly the notification the run was supposed to send.
  local _JSON="$(printf '%s' "${_BODY}" | grep '^{' | head -1)"
  local _PARSED="$(printf '%s' "${_JSON}" | docker run --rm -i --label "${LABEL}" "${IMAGE}" \
    python3 -c 'import json,sys; json.load(sys.stdin); print("valid")' 2>&1 | tail -1)"

  assertEquals "and its body is valid JSON despite a carriage return in the host" "valid" "${_PARSED}"
  assertEquals "and no truncated dump is left behind" "0" \
    "$(inBackupVolume 'ls /backup/*.itest.sql 2>/dev/null | wc -l')"
}

###############################################################################
#### Group: cron - the long running mode, backup-now and the healthcheck
###############################################################################

group_cron() {
  section "cron - schedule, backup-now and healthcheck"

  if ! startMariadb; then
    skip "cron" "the database did not come up"
    return 0
  fi

  resetBackupVolume

  local _NAME="${PREFIX}-cron"

  docker rm -f "${_NAME}" > /dev/null 2>&1

  dockerRun "${_NAME}" \
    -v "${BACKUP_VOLUME}:/backup" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=${MARIADB_HOST}" \
    -e MARIADB_USERNAME=itest \
    -e "MARIADB_PASSWORD=${DB_PASSWORD}" \
    -e MARIADBDUMP_DATABASES=itestdb \
    -e MARIADBDUMP_FILENAME=itest \
    -e "CRON_SCHEDULE=0 3 * * *" \
    -e CRON_RUN_ON_START=true \
    -e HEALTHCHECK_MAX_AGE=1d \
    -e TZ=Europe/Berlin \
    "${IMAGE}"

  RUN_LOG="${LOG_DIR}/cron.log"

  if ! waitFor "${_NAME}" "test -f /tmp/dbbackup.state" 90; then
    docker logs "${_NAME}" > "${RUN_LOG}" 2>&1
    fail "the initial run finishes" "no state file after 90s"
    docker rm -f "${_NAME}" > /dev/null 2>&1
    return 0
  fi

  docker logs "${_NAME}" > "${RUN_LOG}" 2>&1

  assertContains "a valid schedule is accepted" "$(cat "${RUN_LOG}")" "Cron enabled with schedule"
  assertContains "the schedule is read in the configured timezone" "$(cat "${RUN_LOG}")" "timezone: Europe/Berlin"
  assertContains "CRON_RUN_ON_START creates a backup" "$(inBackupVolume 'ls /backup')" ".itest.sql"

  local _HEALTH=0
  docker exec "${_NAME}" bash /epicsoft/healthcheck.sh > /dev/null 2>&1 || _HEALTH=$?
  assertEquals "the healthcheck reports healthy" "0" "${_HEALTH}"

  local _BEFORE="$(inBackupVolume 'ls /backup | wc -l' | tr -d ' ')"

  # the file name has a one second resolution, so a manual run started right after the
  # initial one would overwrite it instead of adding a file
  sleep 2

  local _MANUAL=0
  docker exec "${_NAME}" backup-now > /dev/null 2>&1 || _MANUAL=$?
  assertEquals "'backup-now' runs a backup" "0" "${_MANUAL}"

  local _AFTER="$(inBackupVolume 'ls /backup | wc -l' | tr -d ' ')"

  # names the files it found - a bare 'expected 2, got 3' says nothing about whether a
  # run was missing or one too many happened
  if [ "${_AFTER}" == "$((_BEFORE + 1))" ]; then
    pass "and it produces another file"
  else
    fail "and it produces another file" \
      "expected $((_BEFORE + 1)) file(s), found ${_AFTER}: $(inBackupVolume 'ls /backup' | tr '\n' ' ')"
  fi

  assertEquals "the container is still running" "1" "$(docker ps -q --filter "name=^/${_NAME}$" | wc -l)"

  docker rm -f "${_NAME}" > /dev/null 2>&1

  ## a failing run must not kill the container, but must turn the healthcheck ##
  local _BAD="${PREFIX}-cron-bad"

  docker rm -f "${_BAD}" > /dev/null 2>&1

  dockerRun "${_BAD}" \
    -e BACKUP=mariadb \
    -e "MARIADB_HOST=nowhere-at-all" \
    -e MARIADB_USERNAME=itest \
    -e "MARIADB_PASSWORD=${DB_PASSWORD}" \
    -e MARIADBDUMP_FILENAME=itest \
    -e "CRON_SCHEDULE=0 3 * * *" \
    -e CRON_RUN_ON_START=true \
    "${IMAGE}"

  if ! waitFor "${_BAD}" "test -f /tmp/dbbackup.state" 90; then
    fail "a failing run writes the state file" "no state file after 90s"
    docker rm -f "${_BAD}" > /dev/null 2>&1
    return 0
  fi

  assertEquals "a failed backup does not end the container" "1" \
    "$(docker ps -q --filter "name=^/${_BAD}$" | wc -l)"

  _HEALTH=0
  docker exec "${_BAD}" bash /epicsoft/healthcheck.sh > /dev/null 2>&1 || _HEALTH=$?
  assertEquals "but the healthcheck reports unhealthy" "1" "${_HEALTH}"

  docker rm -f "${_BAD}" > /dev/null 2>&1
}

###############################################################################
#### Group: s3 - opt-in, because the endpoint has to speak TLS
###############################################################################

group_s3() {
  section "s3 - upload to MinIO"

  local _CERT_VOLUME="${PREFIX}-certs"

  docker volume rm -f "${_CERT_VOLUME}" > /dev/null 2>&1
  docker volume create --label "${LABEL}" "${_CERT_VOLUME}" > /dev/null

  # 's3.sh' builds the endpoint as 'https://<S3_ENDPOINT>', so a plain http MinIO cannot
  # be used at all. The certificate is self signed and handed to the aws cli through
  # AWS_CA_BUNDLE, which needs no change to the image
  info "generating a certificate for MinIO"
  docker run --rm --label "${LABEL}" -v "${_CERT_VOLUME}:/certs" "${ALPINE_IMAGE}" sh -c "
    apk add --no-cache openssl > /dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -days 2 -nodes \
      -keyout /certs/private.key -out /certs/public.crt \
      -subj '/CN=${MINIO_HOST}' -addext 'subjectAltName=DNS:${MINIO_HOST}' > /dev/null 2>&1
    chmod 0644 /certs/public.crt /certs/private.key" > /dev/null 2>&1

  if [ -z "$(docker run --rm --label "${LABEL}" -v "${_CERT_VOLUME}:/certs" "${ALPINE_IMAGE}" sh -c 'ls /certs/public.crt 2>/dev/null')" ]; then
    skip "s3 upload" "the certificate could not be generated"
    return 0
  fi

  if ! containerExists "${MINIO_HOST}"; then
    pullImage "${MINIO_IMAGE}"
    info "starting ${MINIO_IMAGE}"
    dockerRun "${MINIO_HOST}" \
      -v "${_CERT_VOLUME}:/root/.minio/certs" \
      -e MINIO_ROOT_USER=itestaccess \
      -e MINIO_ROOT_PASSWORD=itestsecret \
      "${MINIO_IMAGE}" server /data
  fi

  # MinIO is not asked whether it is ready - the bucket is simply created until it works.
  # The image is not guaranteed to carry a shell, so a 'docker exec' probe is no option
  local _READY="false"
  local _TRY=0

  info "creating the bucket"

  while [ ${_TRY} -lt 60 ]; do
    if docker run --rm --network "${NETWORK}" --label "${LABEL}" \
      -v "${_CERT_VOLUME}:/certs" \
      -e AWS_ACCESS_KEY_ID=itestaccess \
      -e AWS_SECRET_ACCESS_KEY=itestsecret \
      -e AWS_DEFAULT_REGION=us-east-1 \
      -e AWS_CA_BUNDLE=/certs/public.crt \
      "${IMAGE}" aws s3 mb "s3://itest" --endpoint-url "https://${MINIO_HOST}:9000" > /dev/null 2>&1; then
      _READY="true"
      break
    fi

    sleep 2
    _TRY=$((_TRY + 1))
  done

  if [ "${_READY}" != "true" ]; then
    skip "s3 upload" "MinIO did not become usable"
    return 0
  fi

  if ! startMariadb; then
    skip "s3 upload" "the database did not come up"
    return 0
  fi

  resetBackupVolume

  local _CODE=0
  runMariadbBackup "s3-upload" \
    -v "${_CERT_VOLUME}:/certs" \
    -e AWS_CA_BUNDLE=/certs/public.crt \
    -e S3_ENABLE=true \
    -e S3_ACCESS_KEY=itestaccess \
    -e S3_SECRET_KEY=itestsecret \
    -e S3_BUCKET=itest \
    -e S3_PREFIX=backup \
    -e S3_REGION=us-east-1 \
    -e "S3_ENDPOINT=${MINIO_HOST}:9000" || _CODE=$?

  assertEquals "the upload succeeds" "0" "${_CODE}"

  local _LIST="$(docker run --rm --network "${NETWORK}" --label "${LABEL}" \
    -v "${_CERT_VOLUME}:/certs" \
    -e AWS_ACCESS_KEY_ID=itestaccess \
    -e AWS_SECRET_ACCESS_KEY=itestsecret \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e AWS_CA_BUNDLE=/certs/public.crt \
    "${IMAGE}" aws s3 ls "s3://itest/backup/" --endpoint-url "https://${MINIO_HOST}:9000" 2>&1)"

  assertContains "the object is in the bucket" "${_LIST}" ".itest.sql"

  ## a fixed object key, plus keys from files and the v4 signature #############
  # 'S3_FILENAME' replaces only the S3 key, not the local file name - that is the
  # 'overwrite in place' pattern, where retention is left to the bucket
  resetSecretVolume
  writeSecretFile "s3-access" "itestaccess"
  writeSecretFile "s3-secret" "itestsecret"

  resetBackupVolume

  _CODE=0
  runMariadbBackup "s3-fixed-key" \
    -v "${_CERT_VOLUME}:/certs" \
    -v "${SECRET_VOLUME}:/secrets" \
    -e AWS_CA_BUNDLE=/certs/public.crt \
    -e S3_ENABLE=true \
    -e S3_ACCESS_KEY_FILE=/secrets/s3-access \
    -e S3_SECRET_KEY_FILE=/secrets/s3-secret \
    -e S3_BUCKET=itest \
    -e S3_PREFIX=fixed \
    -e S3_FILENAME=always-the-same.sql \
    -e S3_REGION=us-east-1 \
    -e S3_S3V4=true \
    -e "S3_ENDPOINT=${MINIO_HOST}:9000" || _CODE=$?

  assertEquals "the upload works with the keys read from files" "0" "${_CODE}"

  _LIST="$(docker run --rm --network "${NETWORK}" --label "${LABEL}" \
    -v "${_CERT_VOLUME}:/certs" \
    -e AWS_ACCESS_KEY_ID=itestaccess \
    -e AWS_SECRET_ACCESS_KEY=itestsecret \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e AWS_CA_BUNDLE=/certs/public.crt \
    "${IMAGE}" aws s3 ls "s3://itest/fixed/" --endpoint-url "https://${MINIO_HOST}:9000" 2>&1)"

  assertContains "S3_FILENAME decides the object key" "${_LIST}" "always-the-same.sql"
  assertContains "and the local file keeps its timestamp name" "$(inBackupVolume 'ls /backup')" ".itest.sql"
}

###############################################################################
#### Main
###############################################################################

cleanup() {
  if [ "${KEEP}" == "true" ]; then
    printf '\n--keep: the containers are left running, remove them with bash test/clean.sh env\n'
    return 0
  fi

  printf '\n'
  bash "${TEST_DIR}/clean.sh" env
}

# only the leading '####' block, not every line starting with it - the section banners
# further down do too
usage() {
  awk '
    /^####/ { started = 1; sub(/^#### ?/, ""); print; next }
    started { exit }
  ' "$0"
}

main() {
  local _GROUPS=""
  local _ARG

  if [ ${#} == 0 ]; then
    usage
    exit 0
  fi

  for _ARG in "${@}"; do
    case "${_ARG}" in
      --list ) echo "${ALL_GROUPS}"; exit 0 ;;
      --help | -h ) usage; exit 0 ;;
      --keep ) KEEP="true" ;;
      default ) _GROUPS="${_GROUPS} ${DEFAULT_GROUPS}" ;;
      all ) _GROUPS="${_GROUPS} ${ALL_GROUPS}" ;;
      -* ) echo "unknown option '${_ARG}'"; exit 1 ;;
      * ) _GROUPS="${_GROUPS} ${_ARG}" ;;
    esac
  done

  # reached by something like '--keep' on its own, which selects no group at all
  if [ -z "${_GROUPS}" ]; then
    echo "no group given"
    echo
    usage
    exit 1
  fi

  if [ -z "$(docker info --format '{{.ServerVersion}}' 2>/dev/null)" ]; then
    echo "docker is not reachable"
    exit 1
  fi

  # a CRLF in a script survives into the image and the container dies with
  # "$'\r': command not found" - a confusing failure to hunt down from a test
  if grep -q $'\r' "${PROJECT_DIR}"/epicsoft/*.sh 2>/dev/null; then
    echo "the scripts in epicsoft/ have CRLF line endings - the image will not run"
    echo "run: git add --renormalize . && git checkout -- epicsoft"
    exit 1
  fi

  # Two runs at once destroy each other: they share the network, the volumes and the
  # container names, and the cleanup of whichever finishes first pulls them out from
  # under the other. That surfaces as 'network not found' in the middle of an unrelated
  # test, which costs far more time to understand than this check costs to run.
  #
  # Checked through docker and not with a lock file: there is no flock on a windows host,
  # and the containers are the shared resource anyway.
  if [ ! -z "$(docker ps -q --filter "label=${LABEL}")" ]; then
    echo "containers of another run are still up:"
    docker ps --filter "label=${LABEL}" --format '  {{.Names}} ({{.Status}})'
    echo
    echo "wait for that run to finish, or remove them with 'bash test/clean.sh env'"
    exit 1
  fi

  mkdir -p "${LOG_DIR}"
  rm -f "${LOG_DIR}"/*.log

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  section "building ${IMAGE}"

  # built from inside the project with '.' as the context: MSYS_NO_PATHCONV keeps git
  # bash from rewriting the container paths, but it would then also hand docker - a
  # windows binary - a '/c/...' build context it cannot resolve. A relative path needs
  # no rewriting either way
  if ! ( cd "${PROJECT_DIR}" && docker build -t "${IMAGE}" --build-arg IMAGE_TAG=test . ) > "${LOG_DIR}/build.log" 2>&1; then
    echo "  the build failed, see ${LOG_DIR}/build.log"
    exit 1
  fi
  info "built"

  docker network create --label "${LABEL}" "${NETWORK}" > /dev/null 2>&1
  resetBackupVolume

  local _GROUP

  # 'all mariadb' or 'default cron' name a group twice, and running one of them twice
  # costs minutes for nothing
  local _UNIQUE=""

  for _GROUP in ${_GROUPS}; do
    case " ${_UNIQUE} " in
      *" ${_GROUP} "* ) continue ;;
    esac

    _UNIQUE="${_UNIQUE} ${_GROUP}"
  done

  for _GROUP in ${_UNIQUE}; do
    if [ -z "$(type -t "group_${_GROUP}")" ]; then
      echo "unknown group '${_GROUP}', known are: ${ALL_GROUPS}"
      exit 1
    fi

    "group_${_GROUP}"
  done

  section "summary"

  printf '  %s test(s), %s failed, %s skipped\n' "${TESTS_RUN}" "${TESTS_FAILED}" "${TESTS_SKIPPED}"

  if [ ${TESTS_FAILED} != 0 ]; then
    local _NAME

    for _NAME in "${FAILED_NAMES[@]}"; do
      printf "  ${COLOR_RED}failed${COLOR_RESET} %s\n" "${_NAME}"
    done

    printf '  logs: %s\n' "${LOG_DIR}"
    exit 1
  fi

  printf "  ${COLOR_GREEN}everything passed${COLOR_RESET}\n"
}

main "${@}"
