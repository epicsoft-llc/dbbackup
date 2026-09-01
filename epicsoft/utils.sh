#!/bin/bash

readonly COLOR_RESET='\033[0m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RED='\033[0;31m'

logInfo() {
  local _MSG=${1:-empty message}
  local _DATE=$(date +%Y%m%d-%H%M%S)
  echo -e "${COLOR_RESET}${_DATE} [INFO] ${_MSG}"
}

logWarn() {
  local _MSG=${1:-empty message}
  local _DATE=$(date +%Y%m%d-%H%M%S)
  echo -e "${COLOR_YELLOW}${_DATE} [WARN] ${_MSG}${COLOR_RESET}";
}

logError() {
  local _MSG=${1:-empty message}
  local _DATE=$(date +%Y%m%d-%H%M%S)
  echo -e "${COLOR_RED}${_DATE} [ERROR] ${_MSG}${COLOR_RESET}";
}

__CLEANUP_FILES=()

# bash keeps only one EXIT handler per shell, so stages must not install their own trap.
# they register their temporary files here and backup.sh removes them centrally
registerCleanupFile() {
  __CLEANUP_FILES+=("${1}")
}

removeCleanupFiles() {
  local _FILE

  for _FILE in "${__CLEANUP_FILES[@]}"; do
    if [ ! -z "${_FILE}" ]; then
      rm -f "${_FILE}"
    fi
  done

  __CLEANUP_FILES=()
}

__FAILURE_CLEANUP_FILES=()

# an aborted dump or compression leaves a truncated file behind - the shell creates the
# redirect target before the command fails. such a file is not a backup and must not
# survive the run, but it is dropped only if the work it belongs to did not finish
registerFailureCleanupFile() {
  __FAILURE_CLEANUP_FILES+=("${1}")
}

# releases exactly <FILE> again, so one stage can never drop the registration of another
clearFailureCleanupFile() {
  local _KEEP=()
  local _FILE

  for _FILE in "${__FAILURE_CLEANUP_FILES[@]}"; do
    if [ "${_FILE}" != "${1}" ]; then
      _KEEP+=("${_FILE}")
    fi
  done

  __FAILURE_CLEANUP_FILES=("${_KEEP[@]}")
}

removeFailureCleanupFiles() {
  local _FILE

  for _FILE in "${__FAILURE_CLEANUP_FILES[@]}"; do
    if [ ! -z "${_FILE}" ] && [ -f "${_FILE}" ]; then
      logInfo "Removing incomplete file '$(basename "${_FILE}")'"
      rm -f "${_FILE}"
    fi
  done

  __FAILURE_CLEANUP_FILES=()
}

# quotes <VALUE> as a JSON string, or 'null' if it is empty
jsonValue() {
  local _VALUE=${1}

  if [ -z "${_VALUE}" ]; then
    printf 'null'
    return 0
  fi

  _VALUE="${_VALUE//\\/\\\\}"
  _VALUE="${_VALUE//\"/\\\"}"
  _VALUE="${_VALUE//$'\t'/\\t}"
  _VALUE="${_VALUE//$'\n'/\\n}"
  _VALUE="${_VALUE//$'\r'/\\r}"

  # A raw control character in a JSON string makes the whole body invalid, and the
  # receiver then drops a notification that was the point of the whole thing. The values
  # that get here are not all validated: the database host, the database list and the S3
  # target come from the environment as they are, and a '\r' rides in with any '.env'
  # file or CI variable that has CRLF line endings. Tab, newline and return are escaped
  # above, the rest has no business in a host name or a file name and is dropped.
  _VALUE="$(printf '%s' "${_VALUE}" | tr -d '\000-\037')"

  printf '"%s"' "${_VALUE}"
}

# passes <VALUE> through as a JSON number, or 'null' if it is not one
jsonNumber() {
  local _VALUE=${1}

  if [ -z "$(echo "${_VALUE}" | grep -E '^-?[0-9]+$')" ]; then
    printf 'null'
    return 0
  fi

  printf '%s' "${_VALUE}"
}

# calls <URL> with <METHOD>, sending <BODY> as JSON on POST, and never lets a broken
# notification turn a good backup into a failed one
callWebhook() {
  local _URL=${1}
  local _NAME=${2}
  local _METHOD=${3}
  local _BODY=${4}
  local _HTTP_CODE=""
  local _RESULT=0

  if [ -z "${_URL}" ]; then
    return 0
  fi

  logInfo "Calling ${_NAME} webhook (${_METHOD})"

  if [ "${_METHOD}" == "POST" ]; then
    # the body goes in over stdin, so it never shows up in the process list
    _HTTP_CODE=$(printf '%s' "${_BODY}" | curl --silent --show-error --location --max-time 10 --retry 2 --output /dev/null --write-out '%{http_code}' --request POST --header 'Content-Type: application/json' --data-binary @- "${_URL}") || _RESULT=$?
  else
    _HTTP_CODE=$(curl --silent --show-error --location --max-time 10 --retry 2 --output /dev/null --write-out '%{http_code}' "${_URL}") || _RESULT=$?
  fi

  if [ ${_RESULT} != 0 ]; then
    logWarn "The ${_NAME} webhook could not be called (curl code: ${_RESULT})"
    return 0
  fi

  if [ -z "$(echo "${_HTTP_CODE}" | grep -E '^2[0-9][0-9]$')" ]; then
    logWarn "The ${_NAME} webhook answered with HTTP ${_HTTP_CODE}"
    return 0
  fi

  logInfo "The ${_NAME} webhook answered with HTTP ${_HTTP_CODE}"
}

# writes a MySQL/MariaDB option file <FILE> containing <PASSWORD> in the [client] group.
# in a quoted option file value only \b \t \n \r \\ \s are escape sequences, so a literal
# backslash has to be doubled and the surrounding quote has to be escaped
writeClientPasswordFile() {
  local _FILE=${1}
  local _PASSWORD=${2}

  _PASSWORD="${_PASSWORD//\\/\\\\}"
  _PASSWORD="${_PASSWORD//\"/\\\"}"

  printf '[client]\npassword="%s"\n' "${_PASSWORD}" > "${_FILE}"
}

# makes sure the file name in <VAR_NAME> is a plain name and nothing else. it ends up in
# a path that is written to and removed with 'rm', in the retention pattern and in the
# sqlite3 dot command, so a '/' would move all of that out of '/backup', a '*' would
# widen retention onto foreign files and a quote would break out of the dot command
#
# checked with 'case' and not with 'grep': grep works line by line and would accept a
# value whose *second* line is harmless, which is exactly how a newline gets through
assertSafeFilename() {
  local _VAR_NAME=${1}
  local _VALUE="${!_VAR_NAME}"

  if [ -z "${_VALUE}" ]; then
    logError "You need to set the '${_VAR_NAME}' environment variable."
    exit 1
  fi

  case "${_VALUE}" in
    *[!A-Za-z0-9._-]* )
      logError "'${_VAR_NAME}' must only contain letters, digits, '.', '_' and '-'."
      exit 1
      ;;
  esac
}

# reads the value of <VAR_NAME> from the file in <VAR_NAME>_FILE, if that variable is set
readSecretFile() {
  local _VAR_NAME=${1}
  local _FILE_VAR_NAME="${_VAR_NAME}_FILE"
  local _FILE_PATH="${!_FILE_VAR_NAME}"

  if [ -z "${_FILE_PATH}" ]; then
    return 0
  fi

  if [ ! -z "${!_VAR_NAME}" ]; then
    logError "You can set either '${_VAR_NAME}' or '${_FILE_VAR_NAME}', not both."
    exit 1
  fi

  if [ ! -f "${_FILE_PATH}" ]; then
    logError "The file '${_FILE_PATH}' from '${_FILE_VAR_NAME}' does not exist."
    exit 1
  fi

  if [ ! -r "${_FILE_PATH}" ]; then
    logError "The file '${_FILE_PATH}' from '${_FILE_VAR_NAME}' is not readable."
    exit 1
  fi

  local _VALUE="$(cat "${_FILE_PATH}")"

  if [ -z "${_VALUE}" ]; then
    logError "The file '${_FILE_PATH}' from '${_FILE_VAR_NAME}' is empty."
    exit 1
  fi

  export "${_VAR_NAME}=${_VALUE}"
  logInfo "Using '${_FILE_VAR_NAME}' as source for '${_VAR_NAME}'"
}
