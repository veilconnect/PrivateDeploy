#!/bin/bash
# Linux 软件包生成脚本 (.deb 和 .rpm)
# 使用 fpm 工具进行打包

set -euo pipefail

APP_NAME="privatedeploy"
APP_DISPLAY_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_ARCHIVE_PATH="${SINGBOX_ARCHIVE_PATH:-}"
SINGBOX_SHA256="${SINGBOX_SHA256:-}"
DESCRIPTION="Private deployment tool with cloud integration and proxy management"
HOMEPAGE="https://github.com/veilconnect/PrivateDeploy"
MAINTAINER="PrivateDeploy Team <team@privatedeploy.dev>"
RUNTIME_DATA_DIR="build/bin/data"

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

prepare_runtime_data() {
    echo "==> 第 2 步: 准备 Linux runtime data"

    local temp_dir
    temp_dir="$(mktemp -d)"
    cleanup_runtime_data() {
        rm -rf "${temp_dir}"
    }
    trap cleanup_runtime_data RETURN

    rm -rf "${RUNTIME_DATA_DIR}"
    mkdir -p "${RUNTIME_DATA_DIR}/sing-box"

    local archive_path="${temp_dir}/sing-box-linux.tar.gz"
    if [[ -n "${SINGBOX_ARCHIVE_PATH}" ]]; then
        if [[ ! -f "${SINGBOX_ARCHIVE_PATH}" ]]; then
            echo "❌ 指定的 SINGBOX_ARCHIVE_PATH 不存在: ${SINGBOX_ARCHIVE_PATH}"
            exit 1
        fi
        echo "  -> 使用本地 sing-box 归档: ${SINGBOX_ARCHIVE_PATH}"
        cp "${SINGBOX_ARCHIVE_PATH}" "${archive_path}"
    else
        local singbox_url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
        echo "  -> 下载 sing-box ${SINGBOX_VERSION} for Linux..."
        curl -LfsS "${singbox_url}" -o "${archive_path}"
    fi

    verify_archive_sha256 "${archive_path}" "${SINGBOX_SHA256}"
    tar -xzf "${archive_path}" -C "${temp_dir}"

    local singbox_bin
    singbox_bin="$(find "${temp_dir}" -name 'sing-box' -type f | head -1)"
    if [[ -z "${singbox_bin}" ]]; then
        echo "❌ 未找到 Linux sing-box 可执行文件"
        exit 1
    fi

    cp "${singbox_bin}" "${RUNTIME_DATA_DIR}/sing-box/sing-box"
    chmod +x "${RUNTIME_DATA_DIR}/sing-box/sing-box"

    if [[ -d "data/.cache" ]]; then
        mkdir -p "${RUNTIME_DATA_DIR}/.cache"
        cp -a "data/.cache/." "${RUNTIME_DATA_DIR}/.cache/"
    fi

    cat > "${RUNTIME_DATA_DIR}/README.txt" <<'EOF'
PrivateDeploy Runtime Data
=========================

This package bundles the Linux sing-box core so the app can start without
manually downloading the kernel on first launch.
EOF

    echo "  ✅ Linux runtime data 已准备就绪"
}

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

# 2. 准备 Linux runtime data
prepare_runtime_data

# 3. 构建 Linux 可执行文件
echo "==> 第 3 步: 构建 Linux 可执行文件"
GOOS=linux GOARCH=amd64 bash "$(dirname "$0")/with_clean_runtime_data.sh" \
  wails build \
  -m -trimpath -skipbindings \
  -devtools -tags webkit2_41 \
  -ldflags "-X privatedeploy/bridge.AppVersion=v${VERSION}" \
  -o "$APP_DISPLAY_NAME"

echo "==> 第 3b 步: 构建 Linux 托盘 sidecar"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -trimpath -buildvcs=false \
  -ldflags "-X privatedeploy/bridge.AppVersion=v${VERSION}" \
  -o "build/bin/privatedeploy-tray" \
  ./cmd/privatedeploy-tray/

# 4. 创建临时打包目录
STAGING_DIR="/tmp/${APP_NAME}-packaging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{usr/bin,usr/lib/${APP_NAME},usr/share/applications,usr/share/pixmaps}

# 5. 复制文件到临时目录
echo "==> 第 4 步: 准备打包文件（排除敏感配置）"
cp "build/bin/$APP_DISPLAY_NAME" "$STAGING_DIR/usr/lib/$APP_NAME/$APP_NAME"
chmod +x "$STAGING_DIR/usr/lib/$APP_NAME/$APP_NAME"
cp "build/bin/privatedeploy-tray" "$STAGING_DIR/usr/lib/$APP_NAME/privatedeploy-tray"
chmod +x "$STAGING_DIR/usr/lib/$APP_NAME/privatedeploy-tray"
ln -s "../lib/$APP_NAME/$APP_NAME" "$STAGING_DIR/usr/bin/$APP_NAME"

# 只复制必要的数据文件（不含敏感配置）
mkdir -p "$STAGING_DIR/usr/lib/${APP_NAME}/data/sing-box"
mkdir -p "$STAGING_DIR/usr/lib/${APP_NAME}/data/subscribes"
mkdir -p "$STAGING_DIR/usr/lib/${APP_NAME}/data/cloud"

# 复制核心文件
cp "build/bin/data/sing-box/sing-box" "$STAGING_DIR/usr/lib/${APP_NAME}/data/sing-box/"
chmod +x "$STAGING_DIR/usr/lib/${APP_NAME}/data/sing-box/sing-box"

# 复制资源文件（图标、图片）
if [ -d "build/bin/data/.cache" ]; then
    cp -r "build/bin/data/.cache" "$STAGING_DIR/usr/lib/${APP_NAME}/data/"
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

# 6. 创建桌面快捷方式文件
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

# 7. 生成 DEB 包
echo "==> 第 5 步: 生成 DEB 包"
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

# 8. 生成 RPM 包
echo "==> 第 6 步: 生成 RPM 包"
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

# 9. 清理
rm -rf "$STAGING_DIR"

echo ""
echo "=== 构建完成 ==="
echo "生成的软件包:"
ls -lh build/bin/*.deb build/bin/*.rpm 2>/dev/null || echo "未找到软件包"
echo ""
echo "安装方法:"
echo "  DEB: sudo dpkg -i build/bin/${APP_NAME}_${VERSION}_amd64.deb"
echo "  RPM: sudo rpm -i build/bin/${APP_NAME}-${VERSION}-1.x86_64.rpm"
