# Android Go Mobile Integration Guide

**English** | [中文](ANDROID_INTEGRATION.zh-CN.md)

This document explains in detail how to integrate the AAR library compiled by Go Mobile into the PrivateDeploy Android application.

---

## 📋 Prerequisites

### Development Environment

- **Android Studio**: Electric Eel or later
- **Android SDK**: API 24+ (Android 7.0+)
- **Android NDK**: r25c or later
- **Go**: 1.21 or later
- **gomobile**: latest version

### Environment Variable Setup

```bash
# Set the Android SDK path
export ANDROID_HOME=$HOME/Android/Sdk

# Set the Android NDK path
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653

# Set the Go path
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
```

---

## 🔧 Step 1: Compile the Go Mobile Library

### 1.1 Install gomobile

```bash
# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# Initialize gomobile
gomobile init
```

### 1.2 Compile the AAR File

```bash
# Enter the gomobile directory
cd ~/PrivateDeploy/mobile/gomobile

# Run the build script
./build-android.sh
```

After a successful compilation, the AAR file will be generated at:
```
~/PrivateDeploy/mobile/android/app/libs/vpncore.aar
```

### 1.3 Verify the AAR File

```bash
# View the AAR contents
unzip -l android/app/libs/vpncore.aar

# It should contain:
# - classes.jar (Java classes)
# - jni/arm64-v8a/libgojni.so
# - jni/armeabi-v7a/libgojni.so
# - jni/x86/libgojni.so
# - jni/x86_64/libgojni.so
# - AndroidManifest.xml
```

---

## 🔗 Step 2: Integrate into the Android Project

### 2.1 Configure build.gradle

Open `android/app/build.gradle` and make sure the libs directory is included:

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
    // Add the AAR dependency
    implementation(name: 'vpncore', ext: 'aar')

    // Kotlin
    implementation "org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.0"

    // AndroidX
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'androidx.appcompat:appcompat:1.6.1'
}
```

### 2.2 Sync the Project

```bash
cd android
./gradlew build
```

---

## 💻 Step 3: Use the Go Library in Code

### 3.1 Import the Go Package

In `PrivateDeployVpnService.kt`:

```kotlin
import com.privatedeploy.mobile.vpncore.Vpncore

class PrivateDeployVpnService : VpnService() {

    private var vpnCore: Vpncore.VPNService? = null

    private fun startVpn(config: String) {
        // ...

        try {
            // Create the VPN Core instance
            vpnCore = Vpncore.NewVPNService()

            // Start the VPN
            vpnCore?.start(config)

            Log.i(TAG, "VPN Core started successfully")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN Core", e)
        }
    }

    private fun stopVpn() {
        try {
            // Stop the VPN Core
            vpnCore?.stop()
            vpnCore = null

            Log.i(TAG, "VPN Core stopped")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop VPN Core", e)
        }
    }
}
```

### 3.2 Handle Packets

```kotlin
private fun startPacketLoop() {
    vpnThread = thread(start = true, name = "VPN-Packet-Loop") {
        val fd = vpnInterface?.fileDescriptor ?: return@thread
        val inputStream = FileInputStream(fd)
        val outputStream = FileOutputStream(fd)
        val buffer = ByteBuffer.allocate(32767)

        while (!Thread.currentThread().isInterrupted && isRunning) {
            try {
                // Read a packet
                val length = inputStream.read(buffer.array())
                if (length > 0) {
                    buffer.limit(length)

                    // Pass it to the Go Mobile VPN Core
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

### 3.3 Get Traffic Statistics

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

## 🐛 Step 4: Debug and Test

### 4.1 Enable Logcat Filtering

```bash
# View VPN service logs
adb logcat | grep PrivateDeployVPN

# View Go logs
adb logcat | grep GoLog

# View all related logs
adb logcat | grep -E "PrivateDeployVPN|GoLog|VpnPlugin"
```

### 4.2 Inspect the TUN Interface

```bash
# View network interfaces
adb shell ip addr show

# View the routing table
adb shell ip route

# View VPN status
adb shell dumpsys connectivity | grep -A 20 VPN
```

### 4.3 Test the VPN Connection

```kotlin
// Test within the app
val vpnService = VpnNativeService.instance

// Start the VPN
val config = """
{
    "log": {"level": "debug"},
    "inbounds": [...],
    "outbounds": [...]
}
"""
vpnService.startVpn(config)

// Check status
val isRunning = vpnService.isRunning()
Log.d(TAG, "VPN Running: $isRunning")

// Get statistics
val stats = vpnService.getStats()
Log.d(TAG, "Upload: ${stats.uploadBytes}, Download: ${stats.downloadBytes}")
```

---

## ⚠️ Common Issues

### Issue 1: AAR File Not Found

**Symptom**: Gradle sync fails, reporting that vpncore.aar cannot be found

**Solution**:
```bash
# Check whether the file exists
ls -lh android/app/libs/vpncore.aar

# If it does not exist, recompile
cd gomobile
./build-android.sh
```

### Issue 2: JNI Library Not Found

**Symptom**: Runtime error `UnsatisfiedLinkError: No implementation found for...`

**Solution**:
```kotlin
// Make sure the library is loaded before use
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

### Issue 3: VPN Permission Denied

**Symptom**: `SecurityException: VPN permission denied`

**Solution**:
```kotlin
// Request VPN permission
val intent = VpnService.prepare(context)
if (intent != null) {
    activity.startActivityForResult(intent, VPN_REQUEST_CODE)
}
```

### Issue 4: Go panic Crash

**Symptom**: The app crashes and the logs show a Go panic

**Solution**:
```kotlin
// Add error handling
try {
    vpnCore?.start(config)
} catch (e: Exception) {
    Log.e(TAG, "Go panic caught", e)
    // Recover or restart
}
```

### Issue 5: Memory Leak

**Symptom**: Memory usage keeps growing after running for a long time

**Solution**:
```kotlin
// Make sure resources are released properly
override fun onDestroy() {
    super.onDestroy()
    vpnCore?.stop()
    vpnCore = null
}
```

---

## 🔒 Security Considerations

### ProGuard Configuration

In `proguard-rules.pro`:

```proguard
# Keep the classes generated by Go Mobile
-keep class com.privatedeploy.mobile.vpncore.** { *; }
-keep class gomobile.** { *; }

# Keep native methods
-keepclassmembers class * {
    native <methods>;
}
```

### Permission Minimization

Request only the required permissions:
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

### Data Encryption

Make sure the configuration file is stored encrypted:
```kotlin
// Encrypt the configuration using the Android Keystore
val keyStore = KeyStore.getInstance("AndroidKeyStore")
// ... encryption logic
```

---

## 📊 Performance Optimization

### 1. Reduce Data Copying

```kotlin
// Use a DirectByteBuffer to avoid copying
val buffer = ByteBuffer.allocateDirect(32767)
```

### 2. Thread Optimization

```kotlin
// Use a dedicated thread pool
private val executor = Executors.newFixedThreadPool(2)

executor.execute {
    // Handle packets
}
```

### 3. Memory Management

```kotlin
// Clean up periodically
System.gc()

// Monitor memory
val runtime = Runtime.getRuntime()
Log.d(TAG, "Memory: ${runtime.totalMemory() - runtime.freeMemory()}")
```

---

## ✅ Verification Checklist

After completing the integration, please verify the following items:

- [ ] The AAR file has been generated successfully
- [ ] Gradle sync has no errors
- [ ] The app compiles normally
- [ ] The VPN can start successfully
- [ ] Packets are forwarded normally
- [ ] Traffic statistics are correct
- [ ] Log output is normal
- [ ] No memory leaks
- [ ] The ProGuard build succeeds
- [ ] On-device testing passes

---

## 📚 References

- [gomobile official documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Android VpnService API](https://developer.android.com/reference/android/net/VpnService)
- [sing-box documentation](https://sing-box.sagernet.org/)
- [Go Mobile Wiki](https://github.com/golang/go/wiki/Mobile)

---

## 🆘 Getting Help

If you run into problems, please:

1. Check the Android Studio Logcat
2. Inspect the gomobile/vpn_service.go implementation
3. Refer to GOMOBILE_INTEGRATION.md
4. Submit an Issue to the project repository

---

*Last updated: 2024-11-05*
