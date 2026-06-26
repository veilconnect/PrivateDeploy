import 'package:flutter/material.dart';

/// Process-wide [ScaffoldMessengerState] that lets background work — code
/// that does not own a [BuildContext], such as [VpnProvider]'s auto-CDN
/// handler — push SnackBars onto whichever Scaffold is currently mounted.
///
/// Wired into [MaterialApp.scaffoldMessengerKey] in `main.dart`. Without
/// this key, the Gate ① auto-deploy path could only `print()` its
/// progress, so users had no idea their Cloudflare account was being
/// touched on their behalf during automatic direct-reachability recovery.
final GlobalKey<ScaffoldMessengerState> globalScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Show a SnackBar via the global messenger if one is currently attached.
/// Safe to call from contexts that never had a BuildContext (e.g.
/// provider callbacks fired by native VPN events). If the app is in the
/// background or the messenger hasn't mounted yet, the call is a no-op
/// — better to silently skip than to crash because of a transient
/// lifecycle gap.
void showGlobalSnackBar(
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
}) {
  final messenger = globalScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      action: action,
    ),
  );
}
