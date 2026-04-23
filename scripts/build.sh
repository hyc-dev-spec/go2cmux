#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="go2cmux.app"
EXECUTABLE_NAME="go2cmux"
SOURCE_FILE="${REPO_ROOT}/go2cmux.swift"
INFO_PLIST_SOURCE="${REPO_ROOT}/Resources/Info.plist"
BUILD_DIR="${REPO_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS_DIR="${APP_CONTENTS}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS}/Resources"
EXECUTABLE_PATH="${APP_MACOS_DIR}/${EXECUTABLE_NAME}"

if [[ ! -f "${SOURCE_FILE}" ]]; then
  echo "Missing source file: ${SOURCE_FILE}" >&2
  exit 1
fi

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
  echo "Missing Info.plist: ${INFO_PLIST_SOURCE}" >&2
  exit 1
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}"

cp "${INFO_PLIST_SOURCE}" "${APP_CONTENTS}/Info.plist"

swiftc -o "${EXECUTABLE_PATH}" "${SOURCE_FILE}"

codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Built app:"
echo "  ${APP_BUNDLE}"
