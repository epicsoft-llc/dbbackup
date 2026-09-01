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

# the schedule is written verbatim into the crontab below, so a newline in it is not a
# broken schedule but a second crontab line that crond runs as root. this has to be
# checked before anything else and it cannot be checked with grep, which works line by
# line and happily matches the harmless first line of a two line value
case "${CRON_SCHEDULE}" in
  *$'\n'* | *$'\r'* )
    logError "'CRON_SCHEDULE' must be a single line."
    exit 1
    ;;
  *[![:blank:]0-9A-Za-z@*,/-]* )
    logError "'CRON_SCHEDULE' must only contain letters, digits, '@', '*', ',', '/', '-' and spaces."
    exit 1
    ;;
esac

# an unusable schedule would only show up as a crond parse error in the log while the
# container keeps running and silently never backs anything up. the keywords are checked
# against the list crond actually knows - accepting every '@...' would have skipped the
# field count for anything starting with '@'
if [ ! -z "$(echo "${CRON_SCHEDULE}" | grep -E '^@')" ]; then
  if [ -z "$(echo "${CRON_SCHEDULE}" | grep -E '^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)$')" ]; then
    logError "'CRON_SCHEDULE' must be '@reboot', '@yearly', '@annually', '@monthly', '@weekly', '@daily', '@midnight' or '@hourly'."
    exit 1
  fi
elif [ "$(echo "${CRON_SCHEDULE}" | wc -w)" != "5" ]; then
  logError "'CRON_SCHEDULE' must have 5 fields, for example '0 3 * * *'."
  exit 1
fi

logInfo "Cron enabled with schedule '${CRON_SCHEDULE}' (timezone: ${TZ:-UTC}, local time: $(date +%Y%m%d-%H%M%S))"

# cron jobs do not inherit the container environment, so snapshot it for cron.sh
( umask 077; export -p > "${CRON_ENV_FILE}" )
chmod 0600 "${CRON_ENV_FILE}"

date +%s > /tmp/dbbackup.started

mkdir -p "${CRON_DIR}"
echo "${CRON_SCHEDULE} ${SCRIPT_DIR}/cron.sh > /proc/1/fd/1 2> /proc/1/fd/2" > "${CRON_FILE}"
chmod 0600 "${CRON_FILE}"

if [ ! -z "$(echo "${CRON_RUN_ON_START}" | grep -i -E "(y|yes|true|1)")" ]; then
  logInfo "Initial backup on start"
  bash "${SCRIPT_DIR}/cron.sh" || true
fi

logInfo "Waiting for next run of schedule '${CRON_SCHEDULE}'"
exec crond -f -d 8 -c "${CRON_DIR}"
