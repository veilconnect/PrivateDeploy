# Android Go Mobile 集成指南

本文档详细说明如何将 Go Mobile 编译的 AAR 库集成到 PrivateDeploy Android 应用中。

---

## 📋 前提条件

### 开发环境

- **Android Studio**: Electric Eel 或更高版本
- **Android SDK**: API 21+ (Android 5.0+)
- **Android NDK**: r25c 或更高版本
- **Go**: 1.21 或更高版本
- **gomobile**: 最新版本

### 环境变量设置

```bash
# 设置 Android SDK 路径
export ANDROID_HOME=$HOME/Android/Sdk

# 设置 Android NDK 路径
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653

# 设置 Go 路径
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
```

---

## 🔧 步骤 1: 编译 Go Mobile 库

### 1.1 安装 gomobile

```bash
# 安装 gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# 初始化 gomobile
gomobile init
```

### 1.2 编译 AAR 文件

```bash
# 进入 gomobile 目录
cd /home/user/PrivateDeploy/mobile/gomobile

# 运行编译脚本
./build-android.sh
```

编译成功后，AAR 文件将生成在：
```
/home/user/PrivateDeploy/mobile/android/app/libs/vpncore.aar
```

### 1.3 验证 AAR 文件

```bash
# 查看 AAR 内容
unzip -l android/app/libs/vpncore.aar

# 应该包含:
# - classes.jar (Java 类)
# - jni/arm64-v8a/libgojni.so
# - jni/armeabi-v7a/libgojni.so
# - jni/x86/libgojni.so
# - jni/x86_64/libgojni.so
# - AndroidManifest.xml
```

---

## 🔗 步骤 2: 集成到 Android 项目

### 2.1 配置 build.gradle

打开 `android/app/build.gradle`，确保包含 libs 目录：

```gradle
android {
    // ...

    repositories {
        flatDir {
            dirs 'libs'
        }
    }
}

dependencies {
    // 添加 AAR 依赖
    implementation(name: 'vpncore', ext: 'aar')

    // Kotlin
    implementation "org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.0"

    // AndroidX
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'androidx.appcompat:appcompat:1.6.1'
}
```

### 2.2 同步项目

```bash
cd android
./gradlew build
```

---

## 💻 步骤 3: 在代码中使用 Go 库

### 3.1 导入 Go 包

在 `PrivateDeployVpnService.kt` 中：

```kotlin
import com.privatedeploy.mobile.vpncore.Vpncore

class PrivateDeployVpnService : VpnService() {

    private var vpnCore: Vpncore.VPNService? = null

    private fun startVpn(config: String) {
        // ...

        try {
            // 创建 VPN Core 实例
            vpnCore = Vpncore.NewVPNService()

            // 启动 VPN
            vpnCore?.start(config)

            Log.i(TAG, "VPN Core started successfully")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN Core", e)
        }
    }

    private fun stopVpn() {
        try {
            // 停止 VPN Core
            vpnCore?.stop()
            vpnCore = null

            Log.i(TAG, "VPN Core stopped")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop VPN Core", e)
        }
    }
}
```

### 3.2 处理数据包

```kotlin
private fun startPacketLoop() {
    vpnThread = thread(start = true, name = "VPN-Packet-Loop") {
        val fd = vpnInterface?.fileDescriptor ?: return@thread
        val inputStream = FileInputStream(fd)
        val outputStream = FileOutputStream(fd)
        val buffer = ByteBuffer.allocate(32767)

        while (!Thread.currentThread().isInterrupted && isRunning) {
            try {
                // 读取数据包
                val length = inputStream.read(buffer.array())
                if (length > 0) {
                    buffer.limit(length)

                    // 传递给 Go Mobile VPN Core
                    vpnCore?.handlePacket(buffer.array(), length.toLong())

                    buffer.clear()
                }
            } catch (e: Exception) {
                if (Thread.currentThread().isInterrupted) break
                Log.e(TAG, "Error in packet loop", e)
            }
        }
    }
}
```

### 3.3 获取流量统计

```kotlin
private fun getStats(): TrafficStats {
    return try {
        val statsJson = vpnCore?.getStats() ?: "{}"
        parseStatsJson(statsJson)
    } catch (e: Exception) {
        Log.e(TAG, "Failed to get stats", e)
        TrafficStats.zero()
    }
}

private fun parseStatsJson(json: String): TrafficStats {
    val data = JSONObject(json)
    return TrafficStats(
        uploadBytes = data.getLong("upload_bytes"),
        downloadBytes = data.getLong("download_bytes"),
        uploadSpeed = data.getLong("upload_speed"),
        downloadSpeed = data.getLong("download_speed")
    )
}
```

---

## 🐛 步骤 4: 调试和测试

### 4.1 启用 Logcat 过滤

```bash
# 查看 VPN 服务日志
adb logcat | grep PrivateDeployVPN

# 查看 Go 日志
adb logcat | grep GoLog

# 查看所有相关日志
adb logcat | grep -E "PrivateDeployVPN|GoLog|VpnPlugin"
```

### 4.2 检查 TUN 接口

```bash
# 查看网络接口
adb shell ip addr show

# 查看路由表
adb shell ip route

# 查看 VPN 状态
adb shell dumpsys connectivity | grep -A 20 VPN
```

### 4.3 测试 VPN 连接

```kotlin
// 在应用中测试
val vpnService = VpnNativeService.instance

// 启动 VPN
val config = """
{
    "log": {"level": "debug"},
    "inbounds": [...],
    "outbounds": [...]
}
"""
vpnService.startVpn(config)

// 检查状态
val isRunning = vpnService.isRunning()
Log.d(TAG, "VPN Running: $isRunning")

// 获取统计
val stats = vpnService.getStats()
Log.d(TAG, "Upload: ${stats.uploadBytes}, Download: ${stats.downloadBytes}")
```

---

## ⚠️ 常见问题

### 问题 1: AAR 文件未找到

**症状**: Gradle 同步失败，提示找不到 vpncore.aar

**解决方案**:
```bash
# 检查文件是否存在
ls -lh android/app/libs/vpncore.aar

# 如果不存在，重新编译
cd gomobile
./build-android.sh
```

### 问题 2: 找不到 JNI 库

**症状**: 运行时错误 `UnsatisfiedLinkError: No implementation found for...`

**解决方案**:
```kotlin
// 确保在使用前加载库
companion object {
    init {
        try {
            System.loadLibrary("gojni")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load native library", e)
        }
    }
}
```

### 问题 3: VPN 权限被拒绝

**症状**: `SecurityException: VPN permission denied`

**解决方案**:
```kotlin
// 请求 VPN 权限
val intent = VpnService.prepare(context)
if (intent != null) {
    activity.startActivityForResult(intent, VPN_REQUEST_CODE)
}
```

### 问题 4: Go panic 崩溃

**症状**: 应用崩溃，日志显示 Go panic

**解决方案**:
```kotlin
// 添加错误处理
try {
    vpnCore?.start(config)
} catch (e: Exception) {
    Log.e(TAG, "Go panic caught", e)
    // 恢复或重启
}
```

### 问题 5: 内存泄漏

**症状**: 长时间运行后内存占用持续增长

**解决方案**:
```kotlin
// 确保正确释放资源
override fun onDestroy() {
    super.onDestroy()
    vpnCore?.stop()
    vpnCore = null
}
```

---

## 🔒 安全考虑

### ProGuard 配置

在 `proguard-rules.pro` 中：

```proguard
# 保留 Go Mobile 生成的类
-keep class com.privatedeploy.mobile.vpncore.** { *; }
-keep class gomobile.** { *; }

# 保留 native 方法
-keepclassmembers class * {
    native <methods>;
}
```

### 权限最小化

只请求必需的权限：
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

### 数据加密

确保配置文件加密存储：
```kotlin
// 使用 Android Keystore 加密配置
val keyStore = KeyStore.getInstance("AndroidKeyStore")
// ... 加密逻辑
```

---

## 📊 性能优化

### 1. 减少数据复制

```kotlin
// 使用 DirectByteBuffer 避免复制
val buffer = ByteBuffer.allocateDirect(32767)
```

### 2. 线程优化

```kotlin
// 使用专用线程池
private val executor = Executors.newFixedThreadPool(2)

executor.execute {
    // 处理数据包
}
```

### 3. 内存管理

```kotlin
// 定期清理
System.gc()

// 监控内存
val runtime = Runtime.getRuntime()
Log.d(TAG, "Memory: ${runtime.totalMemory() - runtime.freeMemory()}")
```

---

## ✅ 验证清单

完成集成后，请验证以下项目：

- [ ] AAR 文件已成功生成
- [ ] Gradle 同步无错误
- [ ] 应用可以正常编译
- [ ] VPN 可以成功启动
- [ ] 数据包正常转发
- [ ] 流量统计正确
- [ ] 日志输出正常
- [ ] 无内存泄漏
- [ ] ProGuard 构建成功
- [ ] 真机测试通过

---

## 📚 参考资料

- [gomobile 官方文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Android VpnService API](https://developer.android.com/reference/android/net/VpnService)
- [sing-box 文档](https://sing-box.sagernet.org/)
- [Go Mobile Wiki](https://github.com/golang/go/wiki/Mobile)

---

## 🆘 获取帮助

如遇到问题，请：

1. 查看 Android Studio Logcat
2. 检查 gomobile/vpn_service.go 实现
3. 参考 GOMOBILE_INTEGRATION.md
4. 提交 Issue 到项目仓库

---

*最后更新: 2024-11-05*
