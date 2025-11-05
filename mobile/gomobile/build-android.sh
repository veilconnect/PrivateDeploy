#!/bin/bash

# PrivateDeploy - Android gomobile 编译脚本
#
# 功能：
# - 编译 Go 代码为 Android AAR 库
# - 支持多架构 (arm, arm64, x86, x86_64)
# - 自动复制到 Android 项目

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  PrivateDeploy - Android Build${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# 检查环境
echo -e "${YELLOW}[1/5] 检查编译环境...${NC}"

# 检查 Go
if ! command -v go &> /dev/null; then
    echo -e "${RED}错误: 未找到 Go 编译器${NC}"
    echo "请安装 Go 1.21 或更高版本"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "✓ Go 版本: $GO_VERSION"

# 检查 gomobile
if ! command -v gomobile &> /dev/null; then
    echo -e "${YELLOW}gomobile 未安装，正在安装...${NC}"
    go install golang.org/x/mobile/cmd/gomobile@latest
    gomobile init
fi

echo "✓ gomobile 已安装"

# 检查 Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    echo -e "${RED}错误: 未设置 ANDROID_NDK_HOME 环境变量${NC}"
    echo "请设置 Android NDK 路径，例如："
    echo "export ANDROID_NDK_HOME=/path/to/android-ndk"
    exit 1
fi

echo "✓ Android NDK: $ANDROID_NDK_HOME"

# 进入 gomobile 目录
cd "$(dirname "$0")"
echo ""
echo -e "${YELLOW}[2/5] 准备依赖...${NC}"

# 下载依赖
echo "正在下载 Go 模块依赖..."
go mod download
go mod tidy

echo "✓ 依赖准备完成"
echo ""

# 编译参数
OUTPUT_DIR="../android/app/libs"
OUTPUT_FILE="vpncore.aar"
PACKAGE_NAME="com.privatedeploy.mobile.vpncore"

echo -e "${YELLOW}[3/5] 清理旧文件...${NC}"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$OUTPUT_FILE"
echo "✓ 清理完成"
echo ""

echo -e "${YELLOW}[4/5] 编译 AAR 库...${NC}"
echo "目标架构: arm, arm64, 386, amd64"
echo "输出文件: $OUTPUT_DIR/$OUTPUT_FILE"
echo ""

# 编译 AAR
# -target=android: 目标平台为 Android
# -o: 输出文件路径
# -javapkg: Java 包名
gomobile bind \
    -target=android \
    -androidapi=21 \
    -javapkg="$PACKAGE_NAME" \
    -o="$OUTPUT_DIR/$OUTPUT_FILE" \
    .

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ 编译成功！${NC}"

    # 显示文件信息
    FILE_SIZE=$(du -h "$OUTPUT_DIR/$OUTPUT_FILE" | cut -f1)
    echo "文件大小: $FILE_SIZE"

    echo ""
    echo -e "${YELLOW}[5/5] 验证 AAR 文件...${NC}"

    # 验证 AAR 文件
    if [ -f "$OUTPUT_DIR/$OUTPUT_FILE" ]; then
        echo "✓ AAR 文件已生成: $OUTPUT_DIR/$OUTPUT_FILE"

        # 列出 AAR 内容
        echo ""
        echo "AAR 内容预览:"
        unzip -l "$OUTPUT_DIR/$OUTPUT_FILE" | head -20

        echo ""
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}  编译完成！${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo ""
        echo "下一步："
        echo "1. 在 Android Studio 中同步项目"
        echo "2. 确保 build.gradle 中包含 libs 目录"
        echo "3. 运行 './gradlew build' 验证集成"
        echo ""

    else
        echo -e "${RED}错误: AAR 文件未生成${NC}"
        exit 1
    fi
else
    echo ""
    echo -e "${RED}编译失败！${NC}"
    echo "请检查错误信息并修复问题"
    exit 1
fi

# 可选：自动触发 Gradle 同步
if command -v gradle &> /dev/null; then
    echo -e "${YELLOW}是否运行 Gradle 同步？(y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cd ../android
        ./gradlew build
    fi
fi
