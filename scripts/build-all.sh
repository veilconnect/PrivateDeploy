#!/bin/bash
# 统一的打包脚本 - 根据当前平台自动选择合适的构建方式

set -e

VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==================================="
echo "  PrivateDeploy 安装程序构建工具"
echo "  版本: $VERSION"
echo "==================================="
echo ""

# 检测当前平台
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="Linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macOS"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="Windows"
else
    echo "❌ 未识别的平台: $OSTYPE"
    exit 1
fi

echo "检测到平台: $PLATFORM"
echo ""

# 显示菜单
echo "请选择要构建的安装程序类型:"
echo "  1) Windows NSIS 安装程序"
echo "  2) Linux DEB 包"
echo "  3) Linux RPM 包"
echo "  4) Linux DEB + RPM 包"
echo "  5) macOS DMG 安装镜像"
echo "  6) 当前平台的默认安装程序"
echo "  7) 仅构建可执行文件 (不打包)"
echo ""
read -p "请输入选项 [1-7] (默认: 6): " choice
choice=${choice:-6}

case $choice in
    1)
        if [[ "$PLATFORM" != "Windows" ]]; then
            echo "⚠️  警告: 当前不在 Windows 平台，NSIS 安装程序可能无法正常生成"
        fi
        bash "$SCRIPT_DIR/build-windows-installer.sh" "$VERSION"
        ;;
    2)
        bash "$SCRIPT_DIR/build-linux-packages.sh" "$VERSION"
        echo "仅保留 DEB 包"
        rm -f build/bin/*.rpm
        ;;
    3)
        bash "$SCRIPT_DIR/build-linux-packages.sh" "$VERSION"
        echo "仅保留 RPM 包"
        rm -f build/bin/*.deb
        ;;
    4)
        bash "$SCRIPT_DIR/build-linux-packages.sh" "$VERSION"
        ;;
    5)
        if [[ "$PLATFORM" != "macOS" ]]; then
            echo "❌ 错误: DMG 安装镜像只能在 macOS 上构建"
            exit 1
        fi
        bash "$SCRIPT_DIR/build-macos-dmg.sh" "$VERSION"
        ;;
    6)
        # 根据平台自动选择
        if [[ "$PLATFORM" == "Linux" ]]; then
            bash "$SCRIPT_DIR/build-linux-packages.sh" "$VERSION"
        elif [[ "$PLATFORM" == "macOS" ]]; then
            bash "$SCRIPT_DIR/build-macos-dmg.sh" "$VERSION"
        elif [[ "$PLATFORM" == "Windows" ]]; then
            bash "$SCRIPT_DIR/build-windows-installer.sh" "$VERSION"
        fi
        ;;
    7)
        echo "==> 仅构建可执行文件"
        cd frontend
        pnpm install
        pnpm run build
        cd ..

        PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -tags webkit2_41

        echo "✅ 可执行文件已生成: build/bin/"
        ls -lh build/bin/ | grep -v "^d"
        ;;
    *)
        echo "❌ 无效的选项"
        exit 1
        ;;
esac

echo ""
echo "==================================="
echo "  构建完成！"
echo "==================================="
