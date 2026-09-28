#!/bin/bash
# Builds MacNetworkMonitor in release mode and wraps it into a proper
# .app bundle. This is needed for "Launch at Login" (SMAppService.mainApp
# requires the running binary to live inside a bundled .app, not a bare
# executable) and gives the app a normal name/identity in the Dock and
# Activity Monitor.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="release"
EXECUTABLE_NAME="MacNetworkMonitor"
APP_NAME="Databar"
APP_BUNDLE=".build/${APP_NAME}.app"

echo "==> Building ${EXECUTABLE_NAME} (${CONFIGURATION})"
swift build -c "${CONFIGURATION}"

BIN_PATH=".build/${CONFIGURATION}/${EXECUTABLE_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
	echo "error: built binary not found at ${BIN_PATH}" >&2
	exit 1
fi

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp "Packaging/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo ""
echo "For 'Launch at Login' to register reliably, install it into /Applications:"
echo "  cp -R \"${APP_BUNDLE}\" /Applications/"
echo "  open \"/Applications/${APP_NAME}.app\""
