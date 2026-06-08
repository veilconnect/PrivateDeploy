#!/bin/bash

# PrivateDeploy - iOS gomobile 编译脚本
#
# 功能：
# - 编译 Go 代码为 iOS Framework
# - 支持 arm64 (真机) 和 x86_64 (模拟器)
# - 自动复制到 iOS 项目

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  PrivateDeploy - iOS Build${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# 检查环境
echo -e "${YELLOW}[1/5] 检查编译环境...${NC}"

# 检查操作系统
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}错误: iOS 编译需要在 macOS 上进行${NC}"
    exit 1
fi

echo "✓ 操作系统: macOS"

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

# 检查 Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}错误: 未找到 Xcode${NC}"
    echo "请安装 Xcode 14 或更高版本"
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version | head -n 1)
echo "✓ $XCODE_VERSION"

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
OUTPUT_DIR="../ios"
FRAMEWORK_NAME="VPNCore.xcframework"
OUTPUT_PATH="$OUTPUT_DIR/$FRAMEWORK_NAME"
TAGS="${PRIVATEDEPLOY_IOS_GOMOBILE_TAGS:-${PRIVATEDEPLOY_GOMOBILE_TAGS:-with_clash_api,with_gvisor,with_wireguard}}"

echo -e "${YELLOW}[3/5] 清理旧文件...${NC}"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_PATH"
echo "✓ 清理完成"
echo ""

echo -e "${YELLOW}[4/5] 编译 Framework...${NC}"
echo "目标架构: arm64 (真机), x86_64 (模拟器)"
echo "Go build tags: ${TAGS:-<none>}"
echo "输出路径: $OUTPUT_PATH"
echo ""

# 编译 Framework
# -target=ios: 目标平台为 iOS
# -o: 输出文件路径
# -iosversion: 最低支持的 iOS 版本
gomobile bind \
    -target=ios \
    -iosversion=12.0 \
    -tags="$TAGS" \
    -o="$OUTPUT_PATH" \
    .

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ 编译成功！${NC}"

    # 显示文件信息
    FRAMEWORK_SIZE=$(du -sh "$OUTPUT_PATH" | cut -f1)
    echo "Framework 大小: $FRAMEWORK_SIZE"

    echo ""
    echo -e "${YELLOW}[5/5] 验证 Framework...${NC}"

    # 验证 XCFramework（内含多个平台切片，逐切片校验）
    if [ -d "$OUTPUT_PATH" ]; then
        echo "✓ XCFramework 已生成: $OUTPUT_PATH"

        echo ""
        echo "包含的切片:"
        ls -1 "$OUTPUT_PATH" | grep -E '^ios' || true

        for slice in "$OUTPUT_PATH"/ios*; do
            BINARY_PATH="$slice/VPNCore.framework/VPNCore"
            [ -f "$BINARY_PATH" ] || continue
            echo ""
            echo "切片 $(basename "$slice") 架构:"
            lipo -info "$BINARY_PATH" || true
        done

        echo ""
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}  编译完成！${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo ""
        echo "下一步："
        echo "1. 在 Xcode 中打开 Runner.xcworkspace"
        echo "2. XCFramework 已在工程中以 Embed & Sign 引用"
        echo "3. 运行项目测试"
        echo ""
    else
        echo -e "${RED}错误: XCFramework 未生成${NC}"
        exit 1
    fi
else
    echo ""
    echo -e "${RED}编译失败！${NC}"
    echo "请检查错误信息并修复问题"
    exit 1
fi

# 可选：自动打开 Xcode
# 非交互环境（CI）下跳过，避免 read 阻塞
if [ -t 0 ]; then
    echo -e "${YELLOW}是否打开 Xcode 项目？(y/n)${NC}"
    read -r response
else
    response="n"
fi
if [[ "$response" =~ ^[Yy]$ ]]; then
    if [ -f "../ios/Runner.xcworkspace" ]; then
        open "../ios/Runner.xcworkspace"
    elif [ -f "../ios/Runner.xcodeproj" ]; then
        open "../ios/Runner.xcodeproj"
    else
        echo -e "${YELLOW}未找到 Xcode 项目文件${NC}"
    fi
fi
