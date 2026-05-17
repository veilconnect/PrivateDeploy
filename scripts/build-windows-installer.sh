#!/bin/bash
# Windows 安装程序生成脚本
# 需要在 Windows 环境或使用 Wine 运行

set -euo pipefail

APP_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_ARCHIVE_PATH="${SINGBOX_ARCHIVE_PATH:-}"
SINGBOX_SHA256="${SINGBOX_SHA256:-}"
RUNTIME_DATA_DIR="build/windows/installer/runtime-data"

verify_archive_sha256() {
  local archive_path="$1"
  local expected_sha256="$2"

  if [[ -z "${expected_sha256}" ]]; then
    return 0
  fi

  echo "  -> 校验 sing-box 归档 SHA256..."
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${expected_sha256}  ${archive_path}" | sha256sum -c -
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    local actual
    actual="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected_sha256}" ]]; then
      echo "❌ SHA256 校验失败: expected ${expected_sha256}, got ${actual}"
      exit 1
    fi
    return 0
  fi

  echo "❌ 无法校验 SHA256：缺少 sha256sum 或 shasum"
  exit 1
}

echo "==> 构建 Windows 安装程序 (版本: $VERSION)"

# 1. 构建前端
echo "==> 第 1 步: 构建前端"
cd frontend
pnpm install
pnpm run build
cd ..

# 2. 准备随安装程序一起分发的 Windows 内核
echo "==> 第 2 步: 准备 Windows runtime data"

TEMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

rm -rf "$RUNTIME_DATA_DIR"
mkdir -p "$RUNTIME_DATA_DIR/data/sing-box"

ARCHIVE_PATH="${TEMP_DIR}/sing-box-windows.zip"
if [[ -n "${SINGBOX_ARCHIVE_PATH}" ]]; then
  if [[ ! -f "${SINGBOX_ARCHIVE_PATH}" ]]; then
    echo "❌ 指定的 SINGBOX_ARCHIVE_PATH 不存在: ${SINGBOX_ARCHIVE_PATH}"
    exit 1
  fi
  echo "  -> 使用本地 sing-box 归档: ${SINGBOX_ARCHIVE_PATH}"
  cp "${SINGBOX_ARCHIVE_PATH}" "${ARCHIVE_PATH}"
else
  SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-windows-amd64.zip"
  echo "  -> 下载 sing-box ${SINGBOX_VERSION} for Windows..."
  curl -LfsS "$SINGBOX_URL" -o "${ARCHIVE_PATH}"
fi

verify_archive_sha256 "${ARCHIVE_PATH}" "${SINGBOX_SHA256}"
unzip -q "${ARCHIVE_PATH}" -d "$TEMP_DIR"

SINGBOX_EXE=$(find "$TEMP_DIR" -name "sing-box.exe" -type f | head -1)
if [ -z "$SINGBOX_EXE" ]; then
  echo "❌ 未找到 sing-box.exe"
  exit 1
fi

cp "$SINGBOX_EXE" "$RUNTIME_DATA_DIR/data/sing-box/sing-box.exe"
chmod +x "$RUNTIME_DATA_DIR/data/sing-box/sing-box.exe"

cat > "$RUNTIME_DATA_DIR/data/README.txt" <<'EOF'
PrivateDeploy Runtime Data
=========================

This installer bundles the Windows sing-box core so the app can start without
manually downloading the kernel on first launch.
EOF

echo "  ✅ Windows runtime data 已准备就绪"

# 3. 构建托盘 sidecar。NSIS 模板会把它安装到主程序旁边。
echo "==> 第 3 步: 构建 Windows 托盘 sidecar"
GOOS=windows GOARCH=amd64 PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 \
  go build \
  -trimpath -buildvcs=false \
  -ldflags "-X privatedeploy/bridge.AppVersion=v${VERSION}" \
  -o "${RUNTIME_DATA_DIR}/privatedeploy-tray.exe" \
  ./cmd/privatedeploy-tray/

# 4. 使用 Wails 构建 Windows 可执行文件并生成 NSIS 安装程序
echo "==> 第 4 步: 构建 Windows 可执行文件和 NSIS 安装程序"

# amd64 版本（带 NSIS 安装程序）
echo "==> 构建 Windows amd64 + NSIS 安装程序"
GOOS=windows GOARCH=amd64 PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 \
  bash "$(dirname "$0")/with_clean_runtime_data.sh" \
  wails build \
  -m -s -trimpath \
  -tags webkit2_41 \
  -ldflags "-X privatedeploy/bridge.AppVersion=v${VERSION}" \
  -nsis \
  -o "$APP_NAME.exe"

# 移动生成的安装程序
if [ -f "build/bin/${APP_NAME}-amd64-installer.exe" ]; then
  mv "build/bin/${APP_NAME}-amd64-installer.exe" "build/bin/${APP_NAME}-${VERSION}-windows-amd64-installer.exe"
  echo "✅ Windows amd64 安装程序已生成: build/bin/${APP_NAME}-${VERSION}-windows-amd64-installer.exe"
fi

echo ""
echo "=== 构建完成 ==="
echo "Windows 安装程序位置:"
ls -lh build/bin/*installer.exe 2>/dev/null || echo "未找到安装程序文件"
