#!/bin/bash
# Linux 软件包生成脚本 (.deb 和 .rpm)
# 使用 fpm 工具进行打包

set -e

APP_NAME="privatedeploy"
APP_DISPLAY_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"
DESCRIPTION="Private deployment tool with cloud integration and proxy management"
HOMEPAGE="https://github.com/PrivateDeploy/PrivateDeploy"
MAINTAINER="PrivateDeploy Team <team@privatedeploy.dev>"

echo "==> 构建 Linux 软件包 (版本: $VERSION)"

# 检查 fpm 是否安装
if ! command -v fpm &> /dev/null; then
    echo "❌ fpm 未安装，正在安装..."
    echo "请运行: sudo apt-get install ruby ruby-dev rubygems build-essential"
    echo "然后运行: sudo gem install fpm"
    exit 1
fi

# 1. 构建前端
echo "==> 第 1 步: 构建前端"
cd frontend
pnpm install
pnpm run build
cd ..

# 2. 构建 Linux 可执行文件
echo "==> 第 2 步: 构建 Linux 可执行文件"
GOOS=linux GOARCH=amd64 wails build \
  -m -s -trimpath -skipbindings \
  -devtools -tags webkit2_41 \
  -o "$APP_DISPLAY_NAME"

# 3. 创建临时打包目录
STAGING_DIR="/tmp/${APP_NAME}-packaging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{usr/bin,usr/share/applications,usr/share/pixmaps,usr/share/${APP_NAME}}

# 4. 复制文件到临时目录
echo "==> 第 3 步: 准备打包文件（排除敏感配置）"
cp "build/bin/$APP_DISPLAY_NAME" "$STAGING_DIR/usr/bin/$APP_NAME"
chmod +x "$STAGING_DIR/usr/bin/$APP_NAME"

# 只复制必要的数据文件（不含敏感配置）
mkdir -p "$STAGING_DIR/usr/share/${APP_NAME}/data/sing-box"
mkdir -p "$STAGING_DIR/usr/share/${APP_NAME}/data/subscribes"
mkdir -p "$STAGING_DIR/usr/share/${APP_NAME}/data/cloud"

# 复制核心文件
cp "build/bin/data/sing-box/sing-box" "$STAGING_DIR/usr/share/${APP_NAME}/data/sing-box/"
chmod +x "$STAGING_DIR/usr/share/${APP_NAME}/data/sing-box/sing-box"

# 复制资源文件（图标、图片）
if [ -d "build/bin/data/.cache" ]; then
    cp -r "build/bin/data/.cache" "$STAGING_DIR/usr/share/${APP_NAME}/data/"
fi

# 不复制敏感文件：
# - config.json (用户配置)
# - cache.db (缓存数据)
# - subscribes/*.json (订阅文件)
# - cloud/*.json (云服务密钥)
# - profiles.yaml (配置文件)
# - subscribes.yaml (订阅配置)

# 复制图标
if [ -f "build/appicon.png" ]; then
    cp build/appicon.png "$STAGING_DIR/usr/share/pixmaps/${APP_NAME}.png"
fi

# 5. 创建桌面快捷方式文件
cat > "$STAGING_DIR/usr/share/applications/${APP_NAME}.desktop" << EOF
[Desktop Entry]
Name=$APP_DISPLAY_NAME
Comment=$DESCRIPTION
Exec=$APP_NAME
Icon=$APP_NAME
Type=Application
Categories=Network;Utility;
Terminal=false
StartupNotify=true
EOF

# 6. 生成 DEB 包
echo "==> 第 4 步: 生成 DEB 包"
fpm -s dir -t deb \
  -n "$APP_NAME" \
  -v "$VERSION" \
  --description "$DESCRIPTION" \
  --url "$HOMEPAGE" \
  --maintainer "$MAINTAINER" \
  --license "MIT" \
  --category "net" \
  --depends "libgtk-3-0" \
  --depends "libwebkit2gtk-4.1-0" \
  -C "$STAGING_DIR" \
  -p "build/bin/${APP_NAME}_${VERSION}_amd64.deb" \
  usr

echo "✅ DEB 包已生成: build/bin/${APP_NAME}_${VERSION}_amd64.deb"

# 7. 生成 RPM 包
echo "==> 第 5 步: 生成 RPM 包"
fpm -s dir -t rpm \
  -n "$APP_NAME" \
  -v "$VERSION" \
  --description "$DESCRIPTION" \
  --url "$HOMEPAGE" \
  --maintainer "$MAINTAINER" \
  --license "MIT" \
  --category "Applications/Internet" \
  --depends "gtk3" \
  --depends "webkit2gtk4.1" \
  -C "$STAGING_DIR" \
  -p "build/bin/${APP_NAME}-${VERSION}-1.x86_64.rpm" \
  usr

echo "✅ RPM 包已生成: build/bin/${APP_NAME}-${VERSION}-1.x86_64.rpm"

# 8. 清理
rm -rf "$STAGING_DIR"

echo ""
echo "=== 构建完成 ==="
echo "生成的软件包:"
ls -lh build/bin/*.deb build/bin/*.rpm 2>/dev/null || echo "未找到软件包"
echo ""
echo "安装方法:"
echo "  DEB: sudo dpkg -i build/bin/${APP_NAME}_${VERSION}_amd64.deb"
echo "  RPM: sudo rpm -i build/bin/${APP_NAME}-${VERSION}-1.x86_64.rpm"
