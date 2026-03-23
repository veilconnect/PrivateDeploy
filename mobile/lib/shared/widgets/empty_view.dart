import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onAction;
  final String? actionLabel;

  const EmptyView({
    Key? key,
    required this.icon,
    required this.title,
    required this.message,
    this.onAction,
    this.actionLabel,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final iconSize = (64.r).clamp(56.0, 88.0);
    final titleSize = (20.sp).clamp(20.0, 32.0);
    final messageSize = (16.sp).clamp(14.0, 20.0);
    final buttonHorizontalPadding = (32.w).clamp(24.0, 40.0);
    final buttonVerticalPadding = (12.h).clamp(10.0, 16.0);

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 520.w.clamp(320.0, 680.0)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: iconSize,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16.h.clamp(12.0, 24.0)),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8.h.clamp(8.0, 16.0)),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: messageSize,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (onAction != null && actionLabel != null) ...[
                    SizedBox(height: 24.h.clamp(16.0, 32.0)),
                    ElevatedButton(
                      onPressed: onAction,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: buttonHorizontalPadding,
                          vertical: buttonVerticalPadding,
                        ),
                      ),
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
