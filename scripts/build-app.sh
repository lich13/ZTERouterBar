#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ZTERouterBar"
BUILD_CONFIG="${1:-release}"
APP_VERSION="${APP_VERSION:-1.3.3}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

cd "${ROOT_DIR}"
SWIFT_BUILD_FLAGS=(
  -c "${BUILD_CONFIG}"
  -Xswiftc -file-prefix-map -Xswiftc "${ROOT_DIR}=/build/ZTERouterBar"
  -Xswiftc -file-prefix-map -Xswiftc "${HOME}=/build"
  -Xswiftc -file-prefix-map -Xswiftc "/private/var/folders=/build/var-folders"
  -Xswiftc -file-prefix-map -Xswiftc "/var/folders=/build/var-folders"
  -Xcc "-ffile-prefix-map=${ROOT_DIR}=/build/ZTERouterBar"
  -Xcc "-ffile-prefix-map=${HOME}=/build"
  -Xcc "-ffile-prefix-map=/private/var/folders=/build/var-folders"
  -Xcc "-ffile-prefix-map=/var/folders=/build/var-folders"
)
swift build "${SWIFT_BUILD_FLAGS[@]}"

BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
if [[ "${BUILD_CONFIG}" == "release" ]]; then
  strip -S -x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" || true
fi

cp "${ROOT_DIR}/Packaging/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [[ -f "${ROOT_DIR}/Packaging/AppIcon.icns" ]]; then
  cp "${ROOT_DIR}/Packaging/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "Built app bundle at: ${APP_BUNDLE} (version ${APP_VERSION})"

if [[ "${PACKAGE_DMG:-0}" == "1" ]]; then
  ARCH="$(uname -m)"
  DMG_NAME="${APP_NAME}-${APP_VERSION}-${ARCH}.dmg"
  DMG_PATH="${DIST_DIR}/${DMG_NAME}"
  DMG_STAGE="${DIST_DIR}/.dmg-stage"

  rm -rf "${DMG_STAGE}" "${DMG_PATH}" "${DMG_PATH}.sha256"
  mkdir -p "${DMG_STAGE}"
  ditto --rsrc --extattr "${APP_BUNDLE}" "${DMG_STAGE}/${APP_NAME}.app"
  ln -s /Applications "${DMG_STAGE}/Applications"

  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

  rm -rf "${DMG_STAGE}"
  (cd "${DIST_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")
  echo "Packaged DMG at: ${DMG_PATH}"
fi
