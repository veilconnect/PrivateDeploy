#!/bin/bash

# PrivateDeploy - Android gomobile 编译脚本
#
# 功能：
# - 编译 Go 代码为 Android AAR 库
# - 默认输出覆盖真机和 x86_64 模拟器
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
SCRIPT_DIR=$(pwd)
echo ""
echo -e "${YELLOW}[2/5] 准备依赖...${NC}"

# 下载依赖
echo "正在下载 Go 模块依赖..."
go mod download
go mod tidy

SING_BOX_VERSION=$(go list -m -f '{{.Version}}' github.com/sagernet/sing-box)
SING_BOX_DIR="$(go env GOMODCACHE)/github.com/sagernet/sing-box@${SING_BOX_VERSION}"
SING_BOX_PATCH="patches/sing-box-${SING_BOX_VERSION}-android-protect-no-default-network-strategy.patch"
SING_BOX_PATCH_PATH="${SCRIPT_DIR}/${SING_BOX_PATCH}"

if [ -f "$SING_BOX_PATCH_PATH" ]; then
    echo "应用 Android sing-box 兼容补丁..."
    if grep -q "if !(networkStrategy == nil" "$SING_BOX_DIR/common/dialer/default.go"; then
        echo "✓ Android sing-box 兼容补丁已存在"
    else
        chmod -R u+w "$SING_BOX_DIR"
        if ! (cd "$SING_BOX_DIR" && patch --forward -p1 < "$SING_BOX_PATCH_PATH"); then
            echo -e "${RED}✗ Android sing-box 兼容补丁应用失败${NC}" >&2
            echo -e "${RED}  补丁路径: $SING_BOX_PATCH_PATH${NC}" >&2
            echo -e "${RED}  sing-box 版本: $SING_BOX_VERSION${NC}" >&2
            echo -e "${RED}  未打补丁的 vpncore 在 Wi-Fi ↔ 蜂窝切换时会连不上 VPN。构建中止。${NC}" >&2
            exit 1
        fi
        if ! grep -q "if !(networkStrategy == nil" "$SING_BOX_DIR/common/dialer/default.go"; then
            echo -e "${RED}✗ 补丁声称已应用，但验证标记缺失。构建中止。${NC}" >&2
            exit 1
        fi
        echo "✓ Android sing-box 兼容补丁已应用"
    fi
else
    echo -e "${RED}✗ 未找到 Android sing-box 兼容补丁 (需要: $SING_BOX_PATCH_PATH)${NC}" >&2
    echo -e "${RED}  请为当前 sing-box 版本 ($SING_BOX_VERSION) 提供补丁文件，否则 Wi-Fi ↔ 蜂窝切换会连不上 VPN。${NC}" >&2
    exit 1
fi

echo "✓ 依赖准备完成"
echo ""

# 编译参数
OUTPUT_DIR="../android/app/libs"
OUTPUT_FILE="vpncore.aar"
PACKAGE_NAME="com.privatedeploy.mobile.vpncore"
TARGETS="${PRIVATEDEPLOY_ANDROID_GOMOBILE_TARGETS:-android/arm64,android/arm,android/amd64}"
# -checklinkname=0: sing-box 1.12's Android pidfd support overrides
# os.checkPidfdOnce via //go:linkname (common/dialer pidfd_android.go). Go's
# linker (1.23+) rejects that cross-package linkname by default
# ("invalid reference to os.checkPidfdOnce"), failing the gomobile link. This
# disables the linkname check, matching upstream sing-box's own Android build.
LDFLAGS="${PRIVATEDEPLOY_ANDROID_GOMOBILE_LDFLAGS:--s -w -checklinkname=0}"
TRIMPATH="${PRIVATEDEPLOY_ANDROID_GOMOBILE_TRIMPATH:-true}"
TAGS="${PRIVATEDEPLOY_ANDROID_GOMOBILE_TAGS:-${PRIVATEDEPLOY_GOMOBILE_TAGS:-with_clash_api,with_gvisor,with_quic,with_utls,with_wireguard}}"

echo -e "${YELLOW}[3/5] 清理旧文件...${NC}"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$OUTPUT_FILE"
echo "✓ 清理完成"
echo ""

echo -e "${YELLOW}[4/5] 编译 AAR 库...${NC}"
echo "目标架构: $TARGETS"
echo "Go build tags: ${TAGS:-<none>}"
echo "Go 链接参数: ${LDFLAGS:-<none>}"
echo "输出文件: $OUTPUT_DIR/$OUTPUT_FILE"
echo ""

# 编译 AAR
# -target=android: 目标平台为 Android
# -o: 输出文件路径
# -javapkg: Java 包名
GOMOBILE_CMD=(
    gomobile bind
    -target="$TARGETS"
    -androidapi=21
    -javapkg="$PACKAGE_NAME"
    -o="$OUTPUT_DIR/$OUTPUT_FILE"
)

if [ -n "$LDFLAGS" ]; then
    GOMOBILE_CMD+=(-ldflags="$LDFLAGS")
fi

if [ -n "$TAGS" ]; then
    GOMOBILE_CMD+=(-tags="$TAGS")
fi

if [ "$TRIMPATH" = "true" ]; then
    GOMOBILE_CMD+=(-trimpath)
fi

GOMOBILE_CMD+=(.)
"${GOMOBILE_CMD[@]}"

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
if [ -t 0 ] && command -v gradle &> /dev/null; then
    echo -e "${YELLOW}是否运行 Gradle 同步？(y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cd ../android
        ./gradlew build
    fi
fi
