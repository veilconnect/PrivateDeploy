#!/bin/bash

set -euo pipefail

APP_NAME="PrivateDeploy"
SOURCE_BIN="build/bin/${APP_NAME}"
SOURCE_CORE="build/bin/data/sing-box/sing-box"
TARGET_BIN_DIR="${HOME}/.local/bin"
TARGET_DATA_DIR="${TARGET_BIN_DIR}/data/sing-box"
TARGET_DESKTOP="${HOME}/.local/share/applications/privatedeploy.desktop"
TARGET_ICON="${HOME}/.local/share/icons/hicolor/256x256/apps/privatedeploy.png"

if [[ ! -f "${SOURCE_BIN}" ]]; then
  echo "❌ 未找到构建产物: ${SOURCE_BIN}"
  exit 1
fi

if [[ ! -f "${SOURCE_CORE}" ]]; then
  echo "❌ 未找到内核文件: ${SOURCE_CORE}"
  exit 1
fi

mkdir -p "${TARGET_BIN_DIR}" "${TARGET_DATA_DIR}" "$(dirname "${TARGET_DESKTOP}")" "$(dirname "${TARGET_ICON}")"

cp -f "${SOURCE_BIN}" "${TARGET_BIN_DIR}/${APP_NAME}"
chmod +x "${TARGET_BIN_DIR}/${APP_NAME}"

cp -f "${SOURCE_CORE}" "${TARGET_DATA_DIR}/sing-box"
chmod +x "${TARGET_DATA_DIR}/sing-box"

if [[ -f "build/appicon.png" ]]; then
  cp -f "build/appicon.png" "${TARGET_ICON}"
fi

cat > "${TARGET_DESKTOP}" <<EOF
[Desktop Entry]
Type=Application
Name=PrivateDeploy
Comment=PrivateDeploy Desktop
Exec=${TARGET_BIN_DIR}/${APP_NAME}
Icon=privatedeploy
Terminal=false
Categories=Network;Utility;
StartupNotify=true
EOF

echo "✅ 已安装到:"
echo "  Binary: ${TARGET_BIN_DIR}/${APP_NAME}"
echo "  Core:   ${TARGET_DATA_DIR}/sing-box"
echo "  Desktop:${TARGET_DESKTOP}"
