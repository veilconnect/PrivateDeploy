import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({Key? key}) : super(key: key);

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final List<LogEntry> _logs = [];
  final _scrollController = ScrollController();
  bool _loading = false;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    setState(() => _loading = true);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final all = _generateOfflineLogs(_filter);

    setState(() {
      _logs
        ..clear()
        ..addAll(all);
      _loading = false;
    });
  }

  List<LogEntry> _generateOfflineLogs(String filter) {
    final now = DateTime.now();
    final base = [
      LogEntry(
        timestamp: now.subtract(const Duration(seconds: 4)),
        level: 'info',
        message: 'App started in mobile standalone mode',
      ),
      LogEntry(
        timestamp: now.subtract(const Duration(seconds: 3)),
        level: 'warn',
        message: 'System dashboard metrics require backend endpoint',
      ),
      LogEntry(
        timestamp: now.subtract(const Duration(seconds: 2)),
        level: 'info',
        message: 'Cloud nodes are managed via direct Vultr API key only',
      ),
      LogEntry(
        timestamp: now,
        level: 'error',
        message: 'No backend logs available in standalone mode',
      ),
    ];

    if (filter == 'all') {
      return base;
    }
    return base.where((item) => item.level == filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            onSelected: (value) {
              setState(() => _filter = value);
              _loadLogs();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('All')),
              PopupMenuItem(value: 'error', child: Text('Errors')),
              PopupMenuItem(value: 'warn', child: Text('Warnings')),
              PopupMenuItem(value: 'info', child: Text('Info')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.article_outlined,
                          size: 48.sp, color: Colors.grey),
                      SizedBox(height: 8.h),
                      const Text('No logs',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) => _buildLogTile(_logs[i]),
                ),
    );
  }

  Widget _buildLogTile(LogEntry entry) {
    final color = switch (entry.level) {
      'error' => Colors.red,
      'warn' => Colors.orange,
      'info' => Colors.blue,
      _ => Colors.grey,
    };

    return ListTile(
      dense: true,
      leading: Icon(
        switch (entry.level) {
          'error' => Icons.error,
          'warn' => Icons.warning,
          _ => Icons.info_outline,
        },
        color: color,
        size: 20.sp,
      ),
      title: Text(
        entry.message,
        style: TextStyle(fontSize: 12.sp, fontFamily: 'monospace'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}',
        style: TextStyle(fontSize: 10.sp, color: Colors.grey),
      ),
    );
  }
}

class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });
}
