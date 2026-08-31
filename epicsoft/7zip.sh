#!/bin/bash

readonly COMPRESS_FILE_NAME="${__BACKUP_FILE_NAME}.7z"

# the archive goes to the backup target, not next to the dump - the dump is
# staged outside '/backup' so that no unpacked copy ever reaches the target
readonly COMPRESS_FILE_PATH="${WORKING_DIR}"
readonly COMPRESS_FILE="${COMPRESS_FILE_PATH}/${COMPRESS_FILE_NAME}"

readSecretFile "COMPRESS_ENCRYPTION_PASSWORD"

if [ -z "${COMPRESS_OPTIONS}" ]; then
  logError "You need to set the 'COMPRESS_OPTIONS' environment variable."
  exit 1
fi

COMPRESS_ARGUMENTS="${COMPRESS_OPTIONS}"
COMPRESS_ENCRYPTED="false"

if [ ! -z "${COMPRESS_ENCRYPTION_PASSWORD}" ]; then
  # p7zip has no password file option, but '-p' without a value makes it read the
  # password from stdin - that keeps it out of the process list and out of 'docker top'
  COMPRESS_ARGUMENTS="${COMPRESS_ARGUMENTS} -mhe -p"
  COMPRESS_ENCRYPTED="true"
fi

mkdir -p "${COMPRESS_FILE_PATH}"

registerFailureCleanupFile "${COMPRESS_FILE}"

# the staged dump is unpacked, so a failing compress stage must not leave it
# behind either - the driver released it when the dump finished
registerFailureCleanupFile "${__BACKUP_FILE}"

if [ "${COMPRESS_ENCRYPTED}" == "true" ]; then
  printf '%s\n' "${COMPRESS_ENCRYPTION_PASSWORD}" | 7z ${COMPRESS_ARGUMENTS} "${COMPRESS_FILE}" "${__BACKUP_FILE}"
else
  7z ${COMPRESS_ARGUMENTS} "${COMPRESS_FILE}" "${__BACKUP_FILE}"
fi

# the archive is complete, so it survives a later failure of another stage
clearFailureCleanupFile "${COMPRESS_FILE}"

rm -rf "${__BACKUP_FILE}"

__BACKUP_FILE_NAME="${COMPRESS_FILE_NAME}"
__BACKUP_FILE_PATH="${COMPRESS_FILE_PATH}"
__BACKUP_FILE="${COMPRESS_FILE}"
__BACKUP_COMPRESSED="true"
__BACKUP_ENCRYPTED="${COMPRESS_ENCRYPTED}"
