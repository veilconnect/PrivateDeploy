import 'package:flutter/material.dart';

void showNodesActionSnackBar(
  BuildContext context, {
  required String message,
  required Color backgroundColor,
  bool replaceCurrent = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (replaceCurrent) {
    messenger.hideCurrentSnackBar();
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: backgroundColor,
    ),
  );
}
