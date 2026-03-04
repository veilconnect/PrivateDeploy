# 打包脚本

这个目录包含用于生成 PrivateDeploy 安装程序的脚本。

## 可用脚本

| 脚本 | 平台 | 描述 | 输出 |
|------|------|------|------|
| `build-all.sh` | 全平台 | 统一构建脚本，自动检测平台 | 根据选择 |
| `build-windows-installer.sh` | Windows | 生成 Windows NSIS 安装程序 | `.exe` 安装程序 |
| `build-linux-packages.sh` | Linux | 生成 DEB 和 RPM 软件包 | `.deb` 和 `.rpm` |
| `build-macos-dmg.sh` | macOS | 生成 macOS DMG 安装镜像 | `.dmg` 镜像 |

## 快速使用

### 推荐方式 (使用统一脚本)

```bash
# 交互式构建
./scripts/build-all.sh

# 指定版本号
./scripts/build-all.sh 1.2.3
```

### 直接使用单独脚本

```bash
# Windows NSIS 安装程序
./scripts/build-windows-installer.sh 1.0.0

# Linux DEB + RPM 包
./scripts/build-linux-packages.sh 1.0.0

# macOS DMG 镜像
./scripts/build-macos-dmg.sh 1.0.0
```

## 前置要求

### 所有平台共同要求
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2

### Windows 特定
- NSIS (由 Wails 自动处理)

### Linux 特定
```bash
# 系统库
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.1-dev

# 打包工具
sudo apt-get install ruby ruby-dev rubygems build-essential
sudo gem install fpm
```

### macOS 特定
- Xcode Command Line Tools

## 输出位置

所有生成的安装程序都位于 `build/bin/` 目录：

- Windows: `PrivateDeploy-{VERSION}-windows-amd64-installer.exe`
- Linux DEB: `privatedeploy_{VERSION}_amd64.deb`
- Linux RPM: `privatedeploy-{VERSION}-1.x86_64.rpm`
- macOS: `PrivateDeploy-{VERSION}-macos.dmg`

## 详细文档

查看 [`docs/PACKAGING.md`](../docs/PACKAGING.md) 获取完整的打包指南。

## 故障排查

### "Permission denied"
```bash
chmod +x scripts/*.sh
```

### "fpm not found" (Linux)
```bash
sudo gem install fpm
```

### "wails not found"
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

## 注意事项

1. **版本号**: 建议使用语义化版本号 (如 `1.2.3`)
2. **清理**: 构建前会自动清理旧文件
3. **平台限制**:
   - NSIS 安装程序只能在 Windows 上生成
   - DMG 镜像只能在 macOS 上生成
   - DEB/RPM 包可以在任何平台生成 (需要 fpm)
