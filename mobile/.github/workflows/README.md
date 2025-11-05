# GitHub Actions 工作流

本目录包含 PrivateDeploy Mobile 的所有 CI/CD 自动化工作流配置。

## 🚀 快速开始

只需将代码推送到 GitHub，工作流会自动运行：

```bash
git add .
git commit -m "feat: add new feature"
git push origin main
```

访问 [Actions 页面](../../actions) 查看构建状态。

## 📋 可用工作流

| 工作流 | 文件 | 触发条件 | 用途 |
|--------|------|----------|------|
| **CI** | `ci.yml` | Push/PR/定时 | 持续集成 |
| **Android** | `build-android.yml` | Push/PR/手动 | 构建 Android APK/AAB |
| **iOS** | `build-ios.yml` | Push/PR/手动 | 构建 iOS IPA |
| **Test** | `test.yml` | Push/PR/手动 | 测试和代码分析 |
| **Release** | `release.yml` | Tag/手动 | 发布新版本 |

## 🎯 常用操作

### 构建 Android APK

**自动方式:**
```bash
git push origin main
```

**手动方式:**
1. 访问 [Actions](../../actions)
2. 选择 "Build Android"
3. 点击 "Run workflow"

### 发布新版本

```bash
# 创建并推送 tag
git tag v1.0.0
git push origin v1.0.0

# 自动构建并发布到 Releases
```

### 下载构建产物

1. 访问 [Actions](../../actions)
2. 点击最新的构建
3. 滚动到 "Artifacts" 部分
4. 下载所需文件

## 📦 构建产物

| 文件 | 工作流 | 大小 |
|------|--------|------|
| `app-release.apk` | Android | ~50MB |
| `app-release.aab` | Android | ~45MB |
| `app-release.ipa` | iOS | ~60MB |
| `vpncore.aar` | Android | ~15MB |
| `VPNCore.framework` | iOS | ~20MB |

## ⏱️ 构建时间

- CI: ~15 分钟
- Android: ~25 分钟
- iOS: ~20 分钟
- Release: ~35 分钟

## 📚 详细文档

查看 [GITHUB_ACTIONS_GUIDE.md](../GITHUB_ACTIONS_GUIDE.md) 了解：
- 详细的工作流说明
- 自定义配置方法
- 故障排除指南
- 最佳实践

## 🔧 自定义配置

### 修改 Flutter 版本

编辑工作流文件中的:
```yaml
flutter-version: '3.16.0'  # 修改这里
```

### 添加环境变量

```yaml
env:
  CUSTOM_VAR: value
```

### 配置 Secrets

Settings → Secrets and variables → Actions → New secret

## ⚠️ 注意事项

1. **Android NDK**: 自动配置，无需手动设置
2. **iOS 签名**: 生成的 IPA 未签名，需手动签名
3. **构建限额**: GitHub Free 提供 2000 分钟/月
4. **Artifact 保留**:
   - CI 构建: 3 天
   - 开发构建: 7 天
   - Release: 30 天

## 🐛 故障排除

### 构建失败

1. 查看失败的 Job 日志
2. 本地复现问题
3. 修复并重新推送

### 常见问题

- **NDK 未找到**: 确保使用 `setup-android` action
- **gomobile 失败**: 检查 Go 版本是否正确
- **Flutter 代码生成失败**: 先运行 `pub get`

## 📞 获取帮助

- 📖 查看 [GITHUB_ACTIONS_GUIDE.md](../GITHUB_ACTIONS_GUIDE.md)
- 🐛 提交 [Issue](../../issues)
- 💬 查看 [Discussions](../../discussions)

---

**最后更新**: 2025-11-05
