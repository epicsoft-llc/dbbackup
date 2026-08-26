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
