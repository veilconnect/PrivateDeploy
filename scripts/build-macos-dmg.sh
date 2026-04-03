#!/bin/bash
# macOS DMG 安装镜像生成脚本
# 需要在 macOS 环境下运行

set -e

APP_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"
DMG_NAME="${APP_NAME}-${VERSION}-macos"

echo "==> 构建 macOS DMG 安装镜像 (版本: $VERSION)"

# 检查是否在 macOS 上运行
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ 此脚本需要在 macOS 上运行"
    exit 1
fi

# 1. 构建前端
echo "==> 第 1 步: 构建前端"
cd frontend
pnpm install
pnpm run build
cd ..

# 2. 修改 AppDelegate.m (设置为配件模式)
echo "==> 第 2 步: 准备构建配置"
go mod vendor
sed -i "" "s/\[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular\]/[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]/g" \
  vendor/github.com/wailsapp/wails/v2/internal/frontend/desktop/darwin/AppDelegate.m

# 3. 构建 macOS 应用
echo "==> 第 3 步: 构建 macOS 应用 (Universal Binary)"

# 构建 arm64 版本
echo "  -> 构建 arm64 版本"
GOOS=darwin GOARCH=arm64 bash "$(dirname "$0")/with_clean_runtime_data.sh" \
  wails build \
  -m -s -trimpath -skipbindings \
  -devtools -tags webkit2_41 \
  -o "$APP_NAME.exe"

mv "build/bin/${APP_NAME}.app" "build/bin/${APP_NAME}-arm64.app"

# 构建 amd64 版本
echo "  -> 构建 amd64 版本"
GOOS=darwin GOARCH=amd64 bash "$(dirname "$0")/with_clean_runtime_data.sh" \
  wails build \
  -m -s -trimpath -skipbindings \
  -devtools -tags webkit2_41 \
  -o "$APP_NAME.exe"

mv "build/bin/${APP_NAME}.app" "build/bin/${APP_NAME}-amd64.app"

# 创建 Universal Binary
echo "  -> 创建 Universal Binary"
cp -R "build/bin/${APP_NAME}-arm64.app" "build/bin/${APP_NAME}.app"
lipo -create \
  "build/bin/${APP_NAME}-arm64.app/Contents/MacOS/${APP_NAME}" \
  "build/bin/${APP_NAME}-amd64.app/Contents/MacOS/${APP_NAME}" \
  -output "build/bin/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# 清理临时文件
rm -rf "build/bin/${APP_NAME}-arm64.app" "build/bin/${APP_NAME}-amd64.app"

# 4. 创建 DMG 安装镜像
echo "==> 第 4 步: 创建 DMG 安装镜像"

# 创建临时目录
DMG_DIR="/tmp/${DMG_NAME}"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# 复制应用到临时目录
cp -R "build/bin/${APP_NAME}.app" "$DMG_DIR/"

# 创建应用程序文件夹的符号链接
ln -s /Applications "$DMG_DIR/Applications"

# 创建 DMG
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDZO \
  "build/bin/${DMG_NAME}.dmg"

# 清理
rm -rf "$DMG_DIR"

echo "✅ DMG 安装镜像已生成: build/bin/${DMG_NAME}.dmg"

echo ""
echo "=== 构建完成 ==="
echo "DMG 文件位置:"
ls -lh build/bin/*.dmg 2>/dev/null || echo "未找到 DMG 文件"
echo ""
echo "安装方法:"
echo "  1. 双击 DMG 文件打开"
echo "  2. 将 $APP_NAME.app 拖拽到 Applications 文件夹"
