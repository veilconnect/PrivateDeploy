# 🚀 GitHub Actions 快速开始

只需 **3 步**，即可通过 GitHub Actions 自动编译 PrivateDeploy Mobile！

---

## ⚡ 快速开始（5 分钟）

### 步骤 1: 推送代码到 GitHub

```bash
cd /home/user/PrivateDeploy/mobile

# 初始化 Git（如果还没有）
git init

# 添加远程仓库（替换成你的仓库地址）
git remote add origin https://github.com/YOUR_USERNAME/PrivateDeploy.git

# 添加所有文件
git add .

# 提交
git commit -m "feat: add PrivateDeploy Mobile with GitHub Actions"

# 推送到 GitHub
git push -u origin main
```

### 步骤 2: 查看自动构建

访问你的仓库 Actions 页面：
```
https://github.com/YOUR_USERNAME/PrivateDeploy/actions
```

你会看到工作流自动开始运行！⚙️

### 步骤 3: 下载构建产物

**等待约 25 分钟**后：

1. 在 Actions 页面找到完成的工作流运行
2. 点击进入查看详情
3. 滚动到底部 "Artifacts" 部分
4. 下载你需要的文件：
   - `app-release.apk` - Android 安装包
   - `app-release.aab` - Google Play 发布包
   - `app-release.ipa` - iOS 安装包

🎉 完成！你现在有了自动编译的 APK/IPA！

---

## 📱 安装测试

### Android
```bash
# 方式 1: 直接安装 APK（推荐）
1. 下载 app-release.apk
2. 传输到 Android 设备
3. 启用"未知来源"
4. 安装 APK

# 方式 2: 使用 adb 安装
adb install app-release.apk
```

### iOS
```bash
# IPA 需要签名后才能安装
1. 下载 app-release.ipa
2. 使用 Xcode 或 TestFlight 重新签名
3. 安装到设备
```

---

## 🔄 发布新版本

### 方法 1: 创建 Tag（自动发布）

```bash
# 1. 创建版本 tag
git tag v1.0.0

# 2. 推送 tag
git push origin v1.0.0

# 3. GitHub Actions 自动：
#    - 创建 GitHub Release
#    - 编译 Android APK/AAB
#    - 编译 iOS IPA
#    - 上传到 Release 页面
```

**35 分钟后**，访问 Releases 页面下载：
```
https://github.com/YOUR_USERNAME/PrivateDeploy/releases
```

### 方法 2: 手动触发

1. 访问 Actions 页面
2. 选择 "Release Build" 工作流
3. 点击 "Run workflow"
4. 输入版本号（例如：1.0.0）
5. 点击 "Run workflow"

---

## 📊 可用的工作流

| 工作流 | 触发方式 | 时间 | 产物 |
|--------|----------|------|------|
| **CI** | 推送代码 | 15分钟 | Debug APK |
| **Android** | 推送/手动 | 25分钟 | APK + AAB |
| **iOS** | 推送/手动 | 20分钟 | IPA |
| **Test** | 推送/手动 | 10分钟 | 测试报告 |
| **Release** | Tag/手动 | 35分钟 | 所有构建 |

---

## 🎯 常见场景

### 场景 1: 我想测试最新代码

```bash
git push origin main
# 等待 15 分钟
# 下载 ci-android-apk
# 安装到设备测试
```

### 场景 2: 我想发布正式版本

```bash
git tag v1.0.0
git push origin v1.0.0
# 等待 35 分钟
# 在 Releases 页面下载
# 发布到应用商店
```

### 场景 3: 我想在本地改完后立即构建

```bash
# 方式 1: 推送触发
git add .
git commit -m "fix: bug fix"
git push

# 方式 2: 手动触发
# Actions → Build Android → Run workflow
```

---

## 💡 小技巧

### 查看实时日志

```
Actions → 点击运行中的工作流 → 点击 Job → 实时查看日志
```

### 重新运行失败的构建

```
点击失败的工作流 → Re-run failed jobs
```

### 添加徽章到 README

在你的 README.md 中添加：

```markdown
![CI](https://github.com/YOUR_USERNAME/PrivateDeploy/workflows/Continuous%20Integration/badge.svg)
```

效果：![CI](https://github.com/YOUR_USERNAME/PrivateDeploy/workflows/Continuous%20Integration/badge.svg)

---

## 📋 构建时间参考

**第一次构建**（需要下载所有依赖）:
- Android: ~30 分钟
- iOS: ~25 分钟

**后续构建**（有缓存）:
- Android: ~20 分钟
- iOS: ~15 分钟

---

## 🔧 故障排除

### Q: 构建失败怎么办？

**A:** 查看日志找到错误原因：
```
Actions → 失败的工作流 → 点击红色的 Job → 查看错误信息
```

常见问题：
- `flutter pub get failed` → 检查 pubspec.yaml
- `gomobile build failed` → 检查 Go 代码语法
- `flutter analyze errors` → 运行本地 `flutter analyze` 修复

### Q: 为什么没有自动触发？

**A:** 检查触发条件：
- 确保推送到了 `main` 或 `develop` 分支
- 检查 `.github/workflows/*.yml` 文件是否存在
- 查看 Actions 页面是否有禁用的工作流

### Q: 如何加速构建？

**A:** GitHub Actions 已自动配置缓存：
- Flutter SDK 缓存
- Gradle 缓存
- Go modules 缓存

第二次构建会明显更快！

---

## 📚 需要更多帮助？

**查看详细文档:**
```
GITHUB_ACTIONS_GUIDE.md       - 18 KB 完整使用指南
.github/workflows/README.md   - 快速参考
GITHUB_ACTIONS_COMPLETE.md    - 配置总结
```

**在线资源:**
- [GitHub Actions 官方文档](https://docs.github.com/en/actions)
- [Flutter CI/CD](https://docs.flutter.dev/deployment/cd)

---

## ✅ 检查清单

使用前确保：
- [x] 代码已推送到 GitHub
- [x] `.github/workflows/` 目录包含所有 YAML 文件
- [x] `gomobile/build-android.sh` 有执行权限
- [x] `gomobile/build-ios.sh` 有执行权限

第一次使用后验证：
- [ ] CI 工作流成功运行
- [ ] 能够下载 APK 文件
- [ ] APK 可以安装到 Android 设备
- [ ] 构建时间符合预期

---

**文档版本**: 1.0.0
**最后更新**: 2025-11-05

🚀 **现在就开始吧！只需一条命令：`git push origin main`**
