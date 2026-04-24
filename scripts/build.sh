#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="go2cmux.app"
EXECUTABLE_NAME="go2cmux"
SOURCE_FILES=(
  "${REPO_ROOT}/Sources/go2cmux/AppDelegate.swift"
  "${REPO_ROOT}/Sources/go2cmux/main.swift"
)
INFO_PLIST_SOURCE="${REPO_ROOT}/Resources/Info.plist"
LIGHT_ICON_MASTER="${REPO_ROOT}/Resources/AppIcon-1024.png"
ASSET_CATALOG_SOURCE="${REPO_ROOT}/Assets.xcassets"
BUILD_DIR="${REPO_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS_DIR="${APP_CONTENTS}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS}/Resources"
EXECUTABLE_PATH="${APP_MACOS_DIR}/${EXECUTABLE_NAME}"
ASSET_INFO_PLIST="${BUILD_DIR}/assetcatalog-info.plist"

for source_file in "${SOURCE_FILES[@]}"; do
  if [[ ! -f "${source_file}" ]]; then
    echo "Missing source file: ${source_file}" >&2
    exit 1
  fi
done

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
  echo "Missing Info.plist: ${INFO_PLIST_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${LIGHT_ICON_MASTER}" ]]; then
  echo "Missing light icon source: ${LIGHT_ICON_MASTER}" >&2
  exit 1
fi

if [[ ! -d "${ASSET_CATALOG_SOURCE}" ]]; then
  echo "Missing asset catalog skeleton: ${ASSET_CATALOG_SOURCE}" >&2
  exit 1
fi

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "Missing actool. Install Xcode to build appearance-aware app icons." >&2
  exit 1
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}"

cp "${INFO_PLIST_SOURCE}" "${APP_CONTENTS}/Info.plist"
"${REPO_ROOT}/scripts/update_appiconset.sh"

xcrun actool \
  --compile "${APP_RESOURCES_DIR}" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "${ASSET_INFO_PLIST}" \
  "${ASSET_CATALOG_SOURCE}" >/dev/null

swiftc -o "${EXECUTABLE_PATH}" "${SOURCE_FILES[@]}"

codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Built app:"
echo "  ${APP_BUNDLE}"
