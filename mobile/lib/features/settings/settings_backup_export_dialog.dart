import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_provider.dart';

Future<void> showSettingsBackupExportDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final payload = await cloud.exportBackupJson();
  await Clipboard.setData(ClipboardData(text: payload));

  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupExportDialog(payload: payload),
  );
}

class _SettingsBackupExportDialog extends StatefulWidget {
  const _SettingsBackupExportDialog({required this.payload});

  final String payload;

  @override
  State<_SettingsBackupExportDialog> createState() =>
      _SettingsBackupExportDialogState();
}

class _SettingsBackupExportDialogState
    extends State<_SettingsBackupExportDialog> {
  late final _BackupExportSummary _summary;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _summary = _BackupExportSummary.fromPayload(widget.payload);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud Backup Copied'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _revealed
                  ? 'Sensitive backup JSON is visible below. Store it safely because it includes your Vultr API key and node credentials.'
                  : 'This backup has already been copied to your clipboard. It contains sensitive data, including your Vultr API key and node credentials.',
            ),
            SizedBox(height: 12.h),
            _BackupSummaryCard(summary: _summary),
            if (_revealed) ...[
              SizedBox(height: 12.h),
              Container(
                width: double.infinity,
                constraints: BoxConstraints(maxHeight: 280.h),
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(widget.payload),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.payload));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Backup copied again')),
              );
            }
          },
          child: const Text('Copy Again'),
        ),
        FilledButton(
          onPressed: _toggleSensitiveJson,
          child: Text(_revealed ? 'Hide JSON' : 'Reveal JSON'),
        ),
      ],
    );
  }

  Future<void> _toggleSensitiveJson() async {
    if (_revealed) {
      setState(() {
        _revealed = false;
      });
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Reveal Sensitive Backup?'),
            content: const Text(
              'This will display the full backup JSON on screen, including the saved API key and node credentials.',
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reveal'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) {
      return;
    }

    setState(() {
      _revealed = true;
    });
  }
}

class _BackupSummaryCard extends StatelessWidget {
  const _BackupSummaryCard({required this.summary});

  final _BackupExportSummary summary;

  @override
  Widget build(BuildContext context) {
    final rows = <({String label, String value})>[
      (label: 'Provider', value: summary.provider),
      (label: 'Node records', value: summary.nodeCount.toString()),
      (
        label: 'API key',
        value: summary.includesApiKey ? 'Included' : 'Not included',
      ),
      (
        label: 'Exported at',
        value: summary.exportedAtLabel ?? 'Unknown',
      ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Backup Summary',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: 8.h),
          for (final row in rows)
            Padding(
              padding: EdgeInsets.only(bottom: 6.h),
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium,
                  children: [
                    TextSpan(
                      text: '${row.label}: ',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    TextSpan(text: row.value),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BackupExportSummary {
  const _BackupExportSummary({
    required this.provider,
    required this.nodeCount,
    required this.includesApiKey,
    required this.exportedAtLabel,
  });

  final String provider;
  final int nodeCount;
  final bool includesApiKey;
  final String? exportedAtLabel;

  factory _BackupExportSummary.fromPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return const _BackupExportSummary(
          provider: 'Unknown',
          nodeCount: 0,
          includesApiKey: false,
          exportedAtLabel: null,
        );
      }

      final records = decoded['nodeRecords'];
      final exportedAt =
          DateTime.tryParse(decoded['exportedAt'] as String? ?? '');
      return _BackupExportSummary(
        provider: (decoded['provider'] as String?) ?? 'Unknown',
        nodeCount: records is Map ? records.length : 0,
        includesApiKey: ((decoded['apiKey'] as String?) ?? '').isNotEmpty,
        exportedAtLabel: exportedAt?.toLocal().toString(),
      );
    } catch (_) {
      return const _BackupExportSummary(
        provider: 'Unknown',
        nodeCount: 0,
        includesApiKey: false,
        exportedAtLabel: null,
      );
    }
  }
}
