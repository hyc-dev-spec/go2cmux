#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LIGHT_ICON_MASTER="${REPO_ROOT}/Resources/AppIcon-1024.png"
DARK_ICON_MASTER="${REPO_ROOT}/Resources/AppIcon-1024-dark.png"
ICONSET_DIR="${REPO_ROOT}/Assets.xcassets/AppIcon.appiconset"

ICON_SIZES=(
  "16 16.png"
  "32 16@2x.png"
  "32 32.png"
  "64 32@2x.png"
  "128 128.png"
  "256 128@2x.png"
  "256 256.png"
  "512 256@2x.png"
  "512 512.png"
  "1024 512@2x.png"
)

if [[ ! -f "${LIGHT_ICON_MASTER}" ]]; then
  echo "Missing light icon source: ${LIGHT_ICON_MASTER}" >&2
  exit 1
fi

if [[ ! -f "${DARK_ICON_MASTER}" ]]; then
  echo "Missing dark icon source: ${DARK_ICON_MASTER}" >&2
  exit 1
fi

if [[ ! -d "${ICONSET_DIR}" ]]; then
  echo "Missing app icon set directory: ${ICONSET_DIR}" >&2
  exit 1
fi

for spec in "${ICON_SIZES[@]}"; do
  read -r size filename <<<"${spec}"
  light_output="${ICONSET_DIR}/${filename}"
  dark_output="${ICONSET_DIR}/${filename%.png}_dark.png"
  sips -z "${size}" "${size}" "${LIGHT_ICON_MASTER}" --out "${light_output}" >/dev/null
  sips -z "${size}" "${size}" "${DARK_ICON_MASTER}" --out "${dark_output}" >/dev/null
done

echo "Updated app icon set:"
echo "  ${ICONSET_DIR}"
