#!/bin/bash

readSecretFile "S3_ACCESS_KEY"
readSecretFile "S3_SECRET_KEY"

if [ -z "${S3_ACCESS_KEY}" ]; then
  logError "You need to set the 'S3_ACCESS_KEY' environment variable."
  exit 1
fi

if [ -z "${S3_SECRET_KEY}" ]; then
  logError "You need to set the 'S3_SECRET_KEY' environment variable."
  exit 1
fi

if [ -z "${S3_BUCKET}" ]; then
  logError "You need to set the 'S3_BUCKET' environment variable."
  exit 1
fi

S3_FILE_NAME="${__BACKUP_FILE_NAME}"
if [ ! -z "${S3_FILENAME}" ]; then
  S3_FILE_NAME="${S3_FILENAME}";
fi

S3_FILE_PATH="/"
if [ ! -z "${S3_PREFIX}" ]; then
  S3_FILE_PATH="/${S3_PREFIX#/}";
  S3_FILE_PATH="${S3_FILE_PATH%/}/"
fi

export AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY}

if [ ! -z "${S3_REGION}" ]; then
  export AWS_DEFAULT_REGION=${S3_REGION}
fi

S3_ARGUMENTS=""
if [ ! -z "${S3_ENDPOINT}" ]; then
  S3_ARGUMENTS="${S3_ARGUMENTS} --endpoint-url https://${S3_ENDPOINT}"
fi

if [ ! -z "$(echo "${S3_S3V4}" | grep -i -E "(y|yes|true|1)")" ]; then
  aws configure set default.s3.signature_version s3v4
fi

logInfo "Uploading '${S3_FILE_NAME}' to S3"

# without the '|| S3_RESULT=$?' the 'set -e' of backup.sh would abort on the aws call
# itself and the error below would never be reached
S3_RESULT=0
aws s3 cp ${__BACKUP_FILE} s3://${S3_BUCKET}${S3_FILE_PATH}${S3_FILE_NAME} ${S3_ARGUMENTS} || S3_RESULT=$?

if [ ${S3_RESULT} != 0 ]; then
  logError "Upload of '${S3_FILE_NAME}' to S3 failed (code: ${S3_RESULT})"
  exit 1
fi

__BACKUP_S3_TARGET="s3://${S3_BUCKET}${S3_FILE_PATH}${S3_FILE_NAME}"
