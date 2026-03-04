#!/bin/bash
# Windows 安装程序生成脚本
# 需要在 Windows 环境或使用 Wine 运行

set -e

APP_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"

echo "==> 构建 Windows 安装程序 (版本: $VERSION)"

# 1. 构建前端
echo "==> 第 1 步: 构建前端"
cd frontend
pnpm install
pnpm run build
cd ..

# 2. 使用 Wails 构建 Windows 可执行文件并生成 NSIS 安装程序
echo "==> 第 2 步: 构建 Windows 可执行文件和 NSIS 安装程序"

# amd64 版本（带 NSIS 安装程序）
echo "==> 构建 Windows amd64 + NSIS 安装程序"
GOOS=windows GOARCH=amd64 wails build \
  -m -s -trimpath -skipbindings \
  -devtools -tags webkit2_41 \
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
