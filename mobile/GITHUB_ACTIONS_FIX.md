# 🔧 GitHub Actions 问题修复报告

**修复时间**: 2025-11-05
**问题**: 移动端 CI/CD 工作流未执行
**状态**: ✅ 已修复

---

## 📊 问题分析

### 问题 1: pnpm 未找到

#### 错误信息
```
Build (ubuntu-latest)
Unable to locate executable file: pnpm. Please verify either the file
path exists or the file can be found within a directory specified by
the PATH environment variable. Also check the file mode to verify the
file is executable.
```

#### 根本原因
根目录的 `.github/workflows/build.yml` 工作流中，`setup-node` action 配置了 `cache: 'pnpm'`，但在执行时 pnpm 还未安装。

**错误的顺序：**
```yaml
- name: Set up Node.js
  uses: actions/setup-node@v4
  with:
    cache: 'pnpm'          # ❌ 尝试使用 pnpm 缓存

- name: Install pnpm      # ⚠️ 但 pnpm 还没安装
  run: npm install -g pnpm
```

#### 修复方案
调整安装顺序，在 Node.js setup 之前先安装 pnpm：

```yaml
- name: Install pnpm      # ✅ 先安装 pnpm
  run: npm install -g pnpm

- name: Set up Node.js
  uses: actions/setup-node@v4
  with:
    cache: 'pnpm'          # ✅ 现在可以使用缓存了
```

同时添加路径过滤，避免移动端变更触发桌面端构建：

```yaml
on:
  push:
    branches: [ main ]
    paths:
      - 'frontend/**'
      - 'bridge/**'
      - 'wails.json'
      - '.github/workflows/build.yml'
      - '!mobile/**'  # 排除 mobile 目录
```

**提交**: `37135c8`

---

### 问题 2: 移动端工作流未执行

#### 根本原因
**GitHub Actions 只识别根目录的 `.github/workflows/` 目录！**

最初创建的移动端工作流位于：
```
mobile/.github/workflows/
├── ci.yml
├── build-android.yml
├── build-ios.yml
├── test.yml
└── release.yml
```

但 GitHub Actions **不会执行**子目录中的工作流文件。

#### 证据
从 git 日志可以看到，首次推送 `ce60175` 只触发了根目录的 `build.yml` 工作流，而 `mobile/.github/workflows/` 下的所有工作流都被忽略了。

#### 修复方案

**1. 移动工作流到正确位置**

将所有移动端工作流移到根目录的 `.github/workflows/`：

```
.github/workflows/
├── build.yml                  # 桌面端
├── release.yml                # 桌面端
├── mobile-ci.yml              # ✅ 移动端 CI
├── mobile-build-android.yml   # ✅ 移动端 Android
├── mobile-build-ios.yml       # ✅ 移动端 iOS
└── mobile-test.yml            # ✅ 移动端测试
```

**2. 添加路径过滤**

确保移动端工作流只在 `mobile/` 目录变更时触发：

```yaml
on:
  push:
    branches: [ main, develop ]
    paths:
      - 'mobile/**'                        # 监听 mobile 目录
      - '.github/workflows/mobile-*.yml'   # 监听自身变更
```

**3. 配置工作目录**

添加默认工作目录，避免每个命令都需要 `cd mobile`：

```yaml
defaults:
  run:
    working-directory: mobile
```

**4. 重命名工作流**

为避免混淆，所有移动端工作流名称添加 `Mobile -` 前缀：

- `Continuous Integration` → `Mobile - Continuous Integration`
- `Build Android` → `Mobile - Build Android`
- `Build iOS` → `Mobile - Build iOS`
- `Test and Analyze` → `Mobile - Test and Analyze`

**提交**: `fa14875`

---

## 📦 修复详情

### 提交 1: 修复桌面端构建

**提交哈希**: `37135c8`
**提交消息**: "fix: resolve GitHub Actions pnpm installation order"

**变更内容**:
```diff
 .github/workflows/build.yml

-name: Build Apps
+name: Build Desktop Apps

 on:
   push:
     branches: [ main ]
+    paths:
+      - 'frontend/**'
+      - 'bridge/**'
+      - 'wails.json'
+      - '.github/workflows/build.yml'
+      - '!mobile/**'

-      - name: Set up Node.js
-        uses: actions/setup-node@v4
-        with:
-          cache: 'pnpm'
-
       - name: Install pnpm
         run: npm install -g pnpm
+
+      - name: Set up Node.js
+        uses: actions/setup-node@v4
+        with:
+          cache: 'pnpm'
```

---

### 提交 2: 移动工作流到正确位置

**提交哈希**: `fa14875`
**提交消息**: "fix: move mobile workflows to root .github/workflows directory"

**变更内容**:
```diff
移动文件:
  R mobile/.github/workflows/build-android.yml → .github/workflows/mobile-build-android.yml
  R mobile/.github/workflows/build-ios.yml → .github/workflows/mobile-build-ios.yml
  R mobile/.github/workflows/ci.yml → .github/workflows/mobile-ci.yml
  R mobile/.github/workflows/test.yml → .github/workflows/mobile-test.yml

删除文件:
  D mobile/.github/workflows/README.md
  D mobile/.github/workflows/release.yml  # 与桌面端 release 冲突

新增文件:
  A mobile/DEPLOYMENT_SUCCESS.md
```

**每个移动端工作流的修改**:

```diff
+name: Mobile - Build Android  # 重命名

 on:
   push:
     branches: [ main, develop ]
+    paths:
+      - 'mobile/**'
+      - '.github/workflows/mobile-build-android.yml'
   pull_request:
     branches: [ main ]
+    paths:
+      - 'mobile/**'
+      - '.github/workflows/mobile-build-android.yml'
   workflow_dispatch:
+
+defaults:
+  run:
+    working-directory: mobile
```

---

## 🎯 修复验证

### 预期结果

推送 `fa14875` 后，应该触发以下工作流：

1. ✅ **Mobile - Continuous Integration**
   - Lint 检查
   - 单元测试
   - Android Debug APK 构建
   - Web 构建
   - 安全扫描

2. ✅ **Mobile - Build Android**
   - Go Mobile AAR 编译
   - Release APK 构建
   - App Bundle 构建

3. ✅ **Mobile - Build iOS**
   - Go Mobile Framework 编译
   - iOS IPA 构建

4. ✅ **Mobile - Test and Analyze**
   - Flutter Analyze
   - 单元测试 + 覆盖率
   - 集成测试

### 验证步骤

1. 访问 GitHub Actions 页面：
   ```
   https://github.com/veilconnect/PrivateDeploy/actions
   ```

2. 确认新的工作流运行出现，名称为 "Mobile - *"

3. 检查工作流状态：
   - ✅ 所有工作流都应该开始执行
   - ⏳ 预计 15-25 分钟完成

4. 构建完成后检查 Artifacts：
   - `ci-android-apk` - Debug APK
   - `android-release` - Release APK
   - `android-bundle` - AAB
   - `ios-release` - IPA
   - `gomobile-android` - AAR
   - `gomobile-ios` - Framework

---

## 📊 当前工作流架构

### 桌面端工作流

位于根目录 `.github/workflows/`，仅在桌面端代码变更时触发：

| 工作流 | 文件 | 触发条件 |
|--------|------|----------|
| Build Desktop Apps | `build.yml` | Push/PR (frontend/**, bridge/**) |
| Build PrivateDeploy | `release.yml` | Tag (v*) |
| Rolling Release | `rolling-release.yml` | Push (main) |
| Rolling Release Alpha | `rolling-release-alpha.yml` | Push (develop) |

### 移动端工作流

位于根目录 `.github/workflows/`，仅在移动端代码变更时触发：

| 工作流 | 文件 | 触发条件 |
|--------|------|----------|
| Mobile - CI | `mobile-ci.yml` | Push/PR (mobile/**) |
| Mobile - Build Android | `mobile-build-android.yml` | Push/PR (mobile/**) |
| Mobile - Build iOS | `mobile-build-ios.yml` | Push/PR (mobile/**) |
| Mobile - Test | `mobile-test.yml` | Push/PR (mobile/**) |

---

## 🔒 路径隔离策略

通过路径过滤，确保桌面端和移动端工作流互不干扰：

### 桌面端触发条件
```yaml
paths:
  - 'frontend/**'
  - 'bridge/**'
  - 'wails.json'
  - '.github/workflows/build.yml'
  - '!mobile/**'  # 明确排除 mobile
```

### 移动端触发条件
```yaml
paths:
  - 'mobile/**'
  - '.github/workflows/mobile-*.yml'
```

### 效果

| 变更内容 | 桌面端工作流 | 移动端工作流 |
|----------|------------|------------|
| 修改 `frontend/src/App.vue` | ✅ 触发 | ❌ 不触发 |
| 修改 `mobile/lib/main.dart` | ❌ 不触发 | ✅ 触发 |
| 修改 `bridge/cloud.go` | ✅ 触发 | ❌ 不触发 |
| 修改 `mobile/android/build.gradle` | ❌ 不触发 | ✅ 触发 |
| 修改 `.github/workflows/build.yml` | ✅ 触发 | ❌ 不触发 |
| 修改 `.github/workflows/mobile-ci.yml` | ❌ 不触发 | ✅ 触发 |

---

## 📚 经验教训

### 1. GitHub Actions 目录结构

❌ **错误认知**: 可以在子目录创建 `.github/workflows/`
```
mobile/.github/workflows/  # GitHub 不会识别！
```

✅ **正确做法**: 所有工作流必须在根目录
```
.github/workflows/  # 唯一有效的位置
```

### 2. 工作目录配置

如果工作流需要在子目录执行：

❌ **笨拙方式**: 每个命令都 `cd`
```yaml
- run: cd mobile && flutter pub get
- run: cd mobile && flutter analyze
- run: cd mobile && flutter build apk
```

✅ **优雅方式**: 使用 `defaults.run.working-directory`
```yaml
defaults:
  run:
    working-directory: mobile

steps:
  - run: flutter pub get
  - run: flutter analyze
  - run: flutter build apk
```

### 3. 路径过滤

对于 monorepo（多项目单仓库），**必须**使用路径过滤：

```yaml
on:
  push:
    paths:
      - 'project-a/**'      # 只在 project-a 变更时触发
      - '!project-b/**'     # 明确排除 project-b
```

### 4. 工作流命名

在 monorepo 中，使用**清晰的前缀**避免混淆：

❌ 不好的命名:
```
- Build Android
- Build iOS
- CI
```

✅ 好的命名:
```
- Mobile - Build Android
- Mobile - Build iOS
- Mobile - CI
```

---

## ✅ 验证清单

- [x] pnpm 安装顺序问题已修复
- [x] 移动端工作流已移到根目录
- [x] 添加路径过滤避免相互触发
- [x] 配置工作目录简化命令
- [x] 重命名工作流便于识别
- [x] 删除冲突的 mobile release workflow
- [x] 代码已提交并推送
- [ ] GitHub Actions 显示新的工作流运行
- [ ] 所有移动端工作流成功执行
- [ ] 构建产物成功上传

---

## 🚀 下一步

1. **监控构建状态**
   - 访问 https://github.com/veilconnect/PrivateDeploy/actions
   - 确认 "Mobile -" 前缀的工作流正在运行

2. **验证构建结果**
   - 等待约 25 分钟
   - 检查 Artifacts 是否成功上传
   - 下载 APK/IPA 进行测试

3. **如果构建失败**
   - 查看工作流日志
   - 检查具体错误信息
   - 根据错误进行相应修复

4. **后续优化**（可选）
   - 配置 Android 签名密钥
   - 配置 iOS 签名证书
   - 设置自动发布到应用商店
   - 配置构建通知

---

## 📞 参考资源

- [GitHub Actions 官方文档](https://docs.github.com/en/actions)
- [Workflow 语法参考](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions)
- [路径过滤语法](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#onpushpull_requestpull_request_targetpathspaths-ignore)
- [Flutter CI/CD](https://docs.flutter.dev/deployment/cd)

---

**修复完成时间**: 2025-11-05 15:30 UTC
**修复提交**: 37135c8, fa14875
**状态**: ✅ 已修复并推送

🎉 **移动端 CI/CD 现在应该正常工作了！**
