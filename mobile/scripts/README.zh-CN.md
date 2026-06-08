# mobile/scripts

[English](README.md) | **中文**

Flutter Android 客户端的构建与校验辅助脚本。

## `build_release.sh`

构建所有 Android release APK(universal + 按 ABI 拆分),并校验每个产物内嵌的 `versionName` / `versionCode` 与当前 `pubspec.yaml` 版本一致。一旦不一致就显式报错失败。

```bash
mobile/scripts/build_release.sh            # universal + 按 ABI 拆分
mobile/scripts/build_release.sh --skip-split   # 仅 universal(更快)
```

该脚本的由来:2026-04-07 我们差点把 2.0.0 连同过时的 1.10.1 release APK 一起发布 —— pubspec 已升到 2.0.0+12,但只重建了 debug APK。请始终用此脚本,而不要直接 `flutter build apk --release`。

## `check_release_apks.sh`

轻量的"现有 APK 是否最新"检查。**不重建** —— 只解析 `pubspec.yaml` 并与 `build/app/outputs/flutter-apk/` 下的 APK 比对。适用于 pre-push 钩子和 CI 门禁:想快速失败、又不愿花 3 分钟以上做完整 release 构建。

```bash
mobile/scripts/check_release_apks.sh
```

## `pre-push.sample`

自动运行 `check_release_apks.sh` 的 Git pre-push 钩子。在本地克隆中启用:

```bash
ln -sf ../../mobile/scripts/pre-push.sample .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

之后,若 release APK 与当前 pubspec 版本不匹配,`git push` 会拒绝继续。用 `build_release.sh` 重建后再 push。
