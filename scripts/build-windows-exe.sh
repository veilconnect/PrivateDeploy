#!/bin/bash
# 在 Linux 上构建 Windows 可执行文件（交叉编译）
# 生成 ZIP 压缩包而不是 NSIS 安装程序

set -e

APP_NAME="PrivateDeploy"
VERSION="${1:-1.0.0}"

echo "==> 在 Linux 上构建 Windows 可执行文件 (版本: $VERSION)"

# 检查是否安装了 mingw-w64
if ! command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "❌ 需要安装 mingw-w64 进行交叉编译"
    echo "运行: sudo apt-get install mingw-w64"
    exit 1
fi

# 1. 构建前端
echo "==> 第 1 步: 构建前端"
cd frontend
pnpm install
pnpm run build
cd ..

# 2. 下载 Windows 版本的 sing-box
echo "==> 第 2 步: 下载 Windows 版本的 sing-box 核心"

SINGBOX_VERSION="1.12.12"  # 最新稳定版本
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-windows-amd64.zip"

# 创建临时目录
TEMP_DIR=$(mktemp -d)
echo "  -> 下载 sing-box ${SINGBOX_VERSION} for Windows..."

if wget -q -O "$TEMP_DIR/sing-box-windows.zip" "$SINGBOX_URL"; then
    echo "  ✅ 下载完成"

    # 解压并提取 sing-box.exe
    unzip -q "$TEMP_DIR/sing-box-windows.zip" -d "$TEMP_DIR"

    # 找到 sing-box.exe 并复制到 data 目录
    SINGBOX_EXE=$(find "$TEMP_DIR" -name "sing-box.exe" -type f | head -1)

    if [ -n "$SINGBOX_EXE" ]; then
        # 备份原有的 Linux 版本
        if [ -f "build/bin/data/sing-box/sing-box" ]; then
            mv "build/bin/data/sing-box/sing-box" "build/bin/data/sing-box/sing-box.linux.bak"
        fi

        # 复制 Windows 版本
        cp "$SINGBOX_EXE" "build/bin/data/sing-box/sing-box.exe"
        chmod +x "build/bin/data/sing-box/sing-box.exe"
        echo "  ✅ sing-box.exe 已准备就绪"
    else
        echo "  ❌ 未找到 sing-box.exe"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
else
    echo "  ❌ 下载失败，请检查网络连接或 sing-box 版本号"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 清理临时文件
rm -rf "$TEMP_DIR"

# 3. 构建 Windows 可执行文件
echo "==> 第 3 步: 交叉编译 Windows 可执行文件"

build_windows() {
    arch=$1
    echo "  -> 构建 Windows $arch 版本"

    if [ "$arch" = "amd64" ]; then
        export CC=x86_64-w64-mingw32-gcc
        export CXX=x86_64-w64-mingw32-g++
    elif [ "$arch" = "386" ]; then
        export CC=i686-w64-mingw32-gcc
        export CXX=i686-w64-mingw32-g++
    fi

    GOOS=windows GOARCH=$arch wails build \
      -m -s -trimpath -skipbindings \
      -devtools -tags webkit2_41 \
      -o "$APP_NAME.exe"

    # 临时移除不需要打包的文件
    BACKUP_DIR=$(mktemp -d)

    # 移除 Linux 版本的 sing-box
    if [ -f "data/sing-box/sing-box.linux.bak" ]; then
        mv "data/sing-box/sing-box.linux.bak" "$BACKUP_DIR/"
    fi
    if [ -f "data/sing-box/sing-box-latest" ]; then
        mv "data/sing-box/sing-box-latest" "$BACKUP_DIR/"
    fi

    # 移除敏感配置文件（安全性）
    echo "  -> 排除敏感配置文件..."
    if [ -f "data/sing-box/config.json" ]; then
        mv "data/sing-box/config.json" "$BACKUP_DIR/"
    fi
    if [ -f "data/sing-box/cache.db" ]; then
        mv "data/sing-box/cache.db" "$BACKUP_DIR/"
    fi
    if [ -f "data/sing-box/pid.txt" ]; then
        mv "data/sing-box/pid.txt" "$BACKUP_DIR/"
    fi
    if [ -f "data/profiles.yaml" ]; then
        mv "data/profiles.yaml" "$BACKUP_DIR/"
    fi
    if [ -f "data/subscribes.yaml" ]; then
        mv "data/subscribes.yaml" "$BACKUP_DIR/"
    fi
    if [ -d "data/subscribes" ] && [ "$(ls -A data/subscribes)" ]; then
        mv "data/subscribes" "$BACKUP_DIR/"
        mkdir -p "data/subscribes"
    fi
    if [ -d "data/cloud" ] && [ "$(ls -A data/cloud)" ]; then
        mv "data/cloud" "$BACKUP_DIR/"
        mkdir -p "data/cloud"
    fi

    # 创建临时打包目录（完全干净）
    echo "  -> 创建干净的打包结构..."
    PACKAGE_DIR=$(mktemp -d)

    # 复制可执行文件
    cp "build/bin/${APP_NAME}.exe" "$PACKAGE_DIR/"

    # 复制必要的资源文件
    mkdir -p "$PACKAGE_DIR/data/.cache"
    cp -r "build/bin/data/.cache/"* "$PACKAGE_DIR/data/.cache/" 2>/dev/null || true

    # 复制 sing-box 核心
    mkdir -p "$PACKAGE_DIR/data/sing-box"
    cp "build/bin/data/sing-box/sing-box.exe" "$PACKAGE_DIR/data/sing-box/"

    # 创建空的配置目录（不含任何配置文件）
    mkdir -p "$PACKAGE_DIR/data/subscribes"
    mkdir -p "$PACKAGE_DIR/data/cloud"

    # 创建说明文件
    cat > "$PACKAGE_DIR/data/README.txt" << 'DATAEOF'
PrivateDeploy Data Directory
============================

This directory contains application data and configuration files.
All configuration will be created automatically on first run.

Directory Structure:
- sing-box/       : Core proxy engine
- subscribes/     : Subscription files (auto-created)
- cloud/          : Cloud service configs (auto-created)
- .cache/         : UI resources and icons

For more information, visit: https://github.com/PrivateDeploy/PrivateDeploy
DATAEOF

    # 从临时目录打包
    cd build/bin
    (cd "$PACKAGE_DIR" && zip -q -r - .) > "${APP_NAME}-${VERSION}-windows-${arch}.zip"

    # 清理
    rm "${APP_NAME}.exe"
    rm -rf "$PACKAGE_DIR"

    # 恢复所有文件
    echo "  -> 恢复原始文件..."
    if [ -f "$BACKUP_DIR/sing-box.linux.bak" ]; then
        mv "$BACKUP_DIR/sing-box.linux.bak" "data/sing-box/sing-box"
    fi
    if [ -f "$BACKUP_DIR/sing-box-latest" ]; then
        mv "$BACKUP_DIR/sing-box-latest" "data/sing-box/"
    fi
    if [ -f "$BACKUP_DIR/config.json" ]; then
        mv "$BACKUP_DIR/config.json" "data/sing-box/"
    fi
    if [ -f "$BACKUP_DIR/cache.db" ]; then
        mv "$BACKUP_DIR/cache.db" "data/sing-box/"
    fi
    if [ -f "$BACKUP_DIR/pid.txt" ]; then
        mv "$BACKUP_DIR/pid.txt" "data/sing-box/"
    fi
    if [ -f "$BACKUP_DIR/profiles.yaml" ]; then
        mv "$BACKUP_DIR/profiles.yaml" "data/"
    fi
    if [ -f "$BACKUP_DIR/subscribes.yaml" ]; then
        mv "$BACKUP_DIR/subscribes.yaml" "data/"
    fi
    if [ -d "$BACKUP_DIR/subscribes" ]; then
        rm -rf "data/subscribes"
        mv "$BACKUP_DIR/subscribes" "data/"
    fi
    if [ -d "$BACKUP_DIR/cloud" ]; then
        rm -rf "data/cloud"
        mv "$BACKUP_DIR/cloud" "data/"
    fi

    # 删除 Windows 版本的 sing-box（已打包到 ZIP）
    rm -f "data/sing-box/sing-box.exe"

    # 清理备份目录
    rm -rf "$BACKUP_DIR"

    cd ../..

    echo "  ✅ ${APP_NAME}-${VERSION}-windows-${arch}.zip"
}

# 构建 amd64 版本
build_windows amd64

echo ""
echo "=== 构建完成 ==="
echo "Windows 可执行文件压缩包:"
ls -lh build/bin/*.zip 2>/dev/null || echo "未找到文件"
echo ""
echo "使用方法:"
echo "  1. 解压 zip 文件"
echo "  2. 运行 $APP_NAME.exe"
echo ""
echo "注意: 这不是安装程序，需要在 Windows 上使用 NSIS 生成安装程序"
