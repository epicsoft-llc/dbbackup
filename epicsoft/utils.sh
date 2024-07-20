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
