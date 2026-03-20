# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /usr/local/Cellar/android-sdk/24.3.3/tools/proguard/proguard-android.txt

# Keep native methods
-keepclassmembers class * {
    native <methods>;
}

# Keep Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep VPN Service
-keep class com.privatedeploy.mobile.** { *; }

# GoMobile generated code
-keep class com.privatedeploy.mobile.vpncore.** { *; }

# Google Play Core (referenced by Flutter but not needed for sideload)
-dontwarn com.google.android.play.core.**

# Kotlin
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings {
    <fields>;
}
