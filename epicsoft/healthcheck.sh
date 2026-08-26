#!/bin/bash

# deliberately standalone: no utils.sh, no colours, no timestamps. docker keeps the last
# line of output and shows it in 'docker inspect', so it has to be a plain reason

readonly HEALTHCHECK_STATE_FILE="/tmp/dbbackup.state"
readonly HEALTHCHECK_STARTED_FILE="/tmp/dbbackup.started"

# a one-shot container is not long running, there is nothing to watch over
if [ -z "${CRON_SCHEDULE}" ]; then
  exit 0
fi

if [ -z "$(pgrep crond)" ]; then
  echo "crond is not running"
  exit 1
fi

HEALTHCHECK_LAST_EPOCH=""
HEALTHCHECK_LAST_CODE=""

if [ -f "${HEALTHCHECK_STATE_FILE}" ]; then
  HEALTHCHECK_LAST_EPOCH="$(cut -d ' ' -f 1 "${HEALTHCHECK_STATE_FILE}")"
  HEALTHCHECK_LAST_CODE="$(cut -d ' ' -f 2 "${HEALTHCHECK_STATE_FILE}")"
fi

if [ ! -z "${HEALTHCHECK_LAST_CODE}" ] && [ "${HEALTHCHECK_LAST_CODE}" != "0" ]; then
  echo "the last backup failed with exit code ${HEALTHCHECK_LAST_CODE}"
  exit 1
fi

# without a maximum age this can only report a dead crond and a failed run - a schedule
# that never fires at all would still look healthy
if [ -z "${HEALTHCHECK_MAX_AGE}" ]; then
  exit 0
fi

HEALTHCHECK_MAX_AGE_NUMBER="${HEALTHCHECK_MAX_AGE//[^0-9]/}"
HEALTHCHECK_MAX_AGE_UNIT="${HEALTHCHECK_MAX_AGE//[0-9]/}"

if [ -z "${HEALTHCHECK_MAX_AGE_NUMBER}" ]; then
  echo "HEALTHCHECK_MAX_AGE '${HEALTHCHECK_MAX_AGE}' is not a duration"
  exit 1
fi

case "${HEALTHCHECK_MAX_AGE_UNIT}" in
  "" | "m" ) HEALTHCHECK_MAX_AGE_SECONDS=$((HEALTHCHECK_MAX_AGE_NUMBER * 60)) ;;
  "h" )      HEALTHCHECK_MAX_AGE_SECONDS=$((HEALTHCHECK_MAX_AGE_NUMBER * 3600)) ;;
  "d" )      HEALTHCHECK_MAX_AGE_SECONDS=$((HEALTHCHECK_MAX_AGE_NUMBER * 86400)) ;;
  * )
    echo "HEALTHCHECK_MAX_AGE '${HEALTHCHECK_MAX_AGE}' has an unknown unit, use m, h or d"
    exit 1
    ;;
esac

# before the first backup the container start is the reference, so a fresh container
# stays healthy until that first run is genuinely overdue
HEALTHCHECK_REFERENCE="${HEALTHCHECK_LAST_EPOCH}"

if [ -z "${HEALTHCHECK_REFERENCE}" ] && [ -f "${HEALTHCHECK_STARTED_FILE}" ]; then
  HEALTHCHECK_REFERENCE="$(cat "${HEALTHCHECK_STARTED_FILE}")"
fi

if [ -z "${HEALTHCHECK_REFERENCE}" ]; then
  exit 0
fi

HEALTHCHECK_AGE=$(($(date +%s) - HEALTHCHECK_REFERENCE))

if [ ${HEALTHCHECK_AGE} -gt ${HEALTHCHECK_MAX_AGE_SECONDS} ]; then
  echo "no successful backup for ${HEALTHCHECK_AGE}s, allowed are ${HEALTHCHECK_MAX_AGE_SECONDS}s"
  exit 1
fi

exit 0
