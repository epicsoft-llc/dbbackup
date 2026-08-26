#!/bin/bash

if [ -z "${__BACKUP_FILE_PATTERN}" ]; then
  logError "The backup script did not provide '__BACKUP_FILE_PATTERN'."
  exit 1
fi

if [ ! -z "${RETENTION_KEEP_LAST}" ] && [ -z "$(echo "${RETENTION_KEEP_LAST}" | grep -E '^[0-9]+$')" ]; then
  logError "'RETENTION_KEEP_LAST' must be a whole number."
  exit 1
fi

if [ ! -z "${RETENTION_KEEP_DAYS}" ] && [ -z "$(echo "${RETENTION_KEEP_DAYS}" | grep -E '^[0-9]+$')" ]; then
  logError "'RETENTION_KEEP_DAYS' must be a whole number."
  exit 1
fi

# a backup is removed only if neither rule wants to keep it, so 'RETENTION_KEEP_LAST'
# is a floor under 'RETENTION_KEEP_DAYS': a broken backup job can never delete the last
# working backups just because they got too old
RETENTION_INDEX=0
RETENTION_KEPT=0
RETENTION_DELETED=0

while IFS= read -r RETENTION_FILE; do
  if [ -z "${RETENTION_FILE}" ]; then
    continue
  fi

  # a failed dump leaves an empty file behind - it is not a backup, so it never counts
  # towards 'RETENTION_KEEP_LAST' and never pushes a real backup out
  if [ ! -s "${RETENTION_FILE}" ] && [ "${RETENTION_FILE}" != "${__BACKUP_FILE}" ]; then
    logInfo "Retention removing empty '$(basename "${RETENTION_FILE}")'"
    rm -f "${RETENTION_FILE}"
    RETENTION_DELETED=$((RETENTION_DELETED + 1))
    continue
  fi

  RETENTION_INDEX=$((RETENTION_INDEX + 1))
  RETENTION_KEEP_REASON=""

  if [ "${RETENTION_FILE}" == "${__BACKUP_FILE}" ]; then
    RETENTION_KEEP_REASON="backup of this run"
  fi

  if [ -z "${RETENTION_KEEP_REASON}" ] && [ ! -z "${RETENTION_KEEP_LAST}" ] && [ ${RETENTION_INDEX} -le ${RETENTION_KEEP_LAST} ]; then
    RETENTION_KEEP_REASON="one of the last ${RETENTION_KEEP_LAST} backups"
  fi

  if [ -z "${RETENTION_KEEP_REASON}" ] && [ ! -z "${RETENTION_KEEP_DAYS}" ] && [ -z "$(find "${RETENTION_FILE}" -mmin +$((RETENTION_KEEP_DAYS * 1440)))" ]; then
    RETENTION_KEEP_REASON="not older than ${RETENTION_KEEP_DAYS} day(s)"
  fi

  if [ ! -z "${RETENTION_KEEP_REASON}" ]; then
    RETENTION_KEPT=$((RETENTION_KEPT + 1))
    continue
  fi

  logInfo "Retention removing '$(basename "${RETENTION_FILE}")'"
  rm -f "${RETENTION_FILE}"
  RETENTION_DELETED=$((RETENTION_DELETED + 1))
done <<< "$(find "${__BACKUP_FILE_PATH}" -maxdepth 1 -type f -name "${__BACKUP_FILE_PATTERN}" | sort -r)"

logInfo "Retention kept ${RETENTION_KEPT} and removed ${RETENTION_DELETED} backup file(s)"
