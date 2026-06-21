# PrivateDeploy 打包和安装程序生成指南

本文档介绍如何为 PrivateDeploy 生成各个平台的安装程序。

## 目录

- [快速开始](#快速开始)
- [Windows 安装程序](#windows-安装程序)
- [Linux 软件包](#linux-软件包)
- [macOS 安装镜像](#macos-安装镜像)
- [常见问题](#常见问题)

## 快速开始

### 使用统一脚本

最简单的方式是使用统一的构建脚本：

```bash
# 使用默认版本号 (1.0.0)
./scripts/build-all.sh

# 指定版本号
./scripts/build-all.sh 1.2.3
```

脚本会自动检测当前平台并显示可用的打包选项。

## Windows 安装程序

### 前置要求

- Windows 操作系统
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- NSIS (由 Wails 自动处理)

### 构建步骤

1. **运行构建脚本**:
   ```bash
   ./scripts/build-windows-installer.sh 1.0.0
   ```

   如需使用预先下载的 `sing-box` 归档并校验 SHA256，可额外传入：
   ```bash
   SINGBOX_ARCHIVE_PATH=/path/to/sing-box-windows-amd64.zip \
   SINGBOX_SHA256=<sha256> \
   ./scripts/build-windows-installer.sh 1.0.0
   ```

2. **手动构建** (可选):
   ```bash
   # 构建前端
   cd frontend
   pnpm install
   pnpm run build
   cd ..

   # 构建 Windows 安装程序
   PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -tags webkit2_41 -nsis -o PrivateDeploy.exe
   ```

3. **输出文件**:
   - 位置: `build/bin/PrivateDeploy-{VERSION}-windows-amd64-installer.exe`
   - 类型: NSIS 安装程序

### 安装程序特性

- ✅ 图形化安装向导
- ✅ 自动创建开始菜单快捷方式
- ✅ 自动创建桌面快捷方式
- ✅ 支持静默安装: `/S` 参数
- ✅ 支持卸载程序

## Linux 软件包

### 前置要求

- Linux 操作系统 (推荐 Ubuntu 20.04+)
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- GTK3 和 WebKit2GTK 开发库
- fpm 打包工具

### 安装依赖

```bash
# 安装系统依赖
sudo apt-get update
sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev

# 安装 Ruby 和 fpm
sudo apt-get install -y ruby ruby-dev rubygems build-essential
sudo gem install fpm
```

### 构建步骤

1. **运行构建脚本**:
   ```bash
   # 生成 DEB 和 RPM 包
   ./scripts/build-linux-packages.sh 1.0.0
   ```

2. **输出文件**:
   - DEB 包: `build/bin/privatedeploy_{VERSION}_amd64.deb`
   - RPM 包: `build/bin/privatedeploy-{VERSION}-1.x86_64.rpm`

### 安装方法

**Debian/Ubuntu (DEB)**:
```bash
sudo dpkg -i build/bin/privatedeploy_1.0.0_amd64.deb
sudo apt-get install -f  # 安装依赖
```

**RedHat/CentOS/Fedora (RPM)**:
```bash
sudo rpm -i build/bin/privatedeploy-1.0.0-1.x86_64.rpm
```

### 软件包内容

- 可执行文件: `/usr/bin/privatedeploy`
- 数据文件: `/usr/share/privatedeploy/data/`
- 桌面快捷方式: `/usr/share/applications/privatedeploy.desktop`
- 图标: `/usr/share/pixmaps/privatedeploy.png`

## macOS 安装镜像

### 前置要求

- macOS 操作系统
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- Xcode Command Line Tools

### 构建步骤

1. **运行构建脚本**:
   ```bash
   ./scripts/build-macos-dmg.sh 1.0.0
   ```

2. **输出文件**:
   - 位置: `build/bin/PrivateDeploy-{VERSION}-macos.dmg`
   - 类型: DMG 安装镜像 (Universal Binary - 支持 Intel 和 Apple Silicon)

### 安装方法

1. 双击 DMG 文件打开
2. 将 PrivateDeploy.app 拖拽到 Applications 文件夹
3. 从启动台或 Finder 中打开应用

### Universal Binary

生成的 DMG 包含 Universal Binary，同时支持:
- Intel (x86_64) 处理器
- Apple Silicon (ARM64) 处理器

## 仅构建可执行文件

如果只需要可执行文件而不需要安装程序:

```bash
# 构建前端
cd frontend
pnpm install
pnpm run build
cd ..

# 构建可执行文件
PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -tags webkit2_41
```

可执行文件位于 `build/bin/` 目录。

## 跨平台构建

### 在 Linux 上构建 Windows 版本

```bash
# 需要安装 mingw-w64
sudo apt-get install mingw-w64

# 设置交叉编译环境变量
export GOOS=windows
export GOARCH=amd64
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++

# 构建
PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -o PrivateDeploy.exe
```

**注意**: NSIS 安装程序只能在 Windows 上生成。

## CI/CD 自动化构建

项目包含 GitHub Actions 工作流，可以自动构建所有平台的安装程序:

- **发布版本**: 推送标签 `v*` 触发 (`release.yml`)
- **滚动发布**: 推送到主分支触发 (`rolling-release.yml`)

查看 `.github/workflows/` 目录了解详情。

## 常见问题

### Q: Windows 上提示 "NSIS not found"

**A**: Wails 会自动下载 NSIS。如果失败，可以手动安装:
1. 从 https://nsis.sourceforge.io/ 下载 NSIS
2. 安装到默认路径
3. 重新运行构建脚本

### Q: Linux 上提示 "fpm not found"

**A**: 安装 fpm 打包工具:
```bash
sudo apt-get install ruby ruby-dev rubygems build-essential
sudo gem install fpm
```

### Q: macOS 上提示代码签名错误

**A**: 开发版本不需要签名。如果要发布到 App Store，需要:
1. 注册 Apple Developer 账号
2. 创建开发者证书
3. 使用 `codesign` 命令签名应用

### Q: 如何减小安装包大小?

**A**: 可以使用 UPX 压缩:
```bash
wails build -upx -upxflags "--best --lzma"
```

**注意**: UPX 可能导致某些杀毒软件误报。

### Q: 构建时出现内存不足错误

**A**: 可以限制并行构建:
```bash
GOMAXPROCS=2 wails build ...
```

## 脚本权限

所有脚本需要执行权限:

```bash
chmod +x scripts/*.sh
```

## 更多信息

- [Wails 官方文档](https://wails.io/docs/guides/building)
- [FPM 打包工具](https://fpm.readthedocs.io/)
- [NSIS 文档](https://nsis.sourceforge.io/Docs/)

## 许可证

本项目遵循 MIT 许可证。
