import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/network/api_client.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({Key? key}) : super(key: key);

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final List<LogEntry> _logs = [];
  bool _loading = false;
  String _filter = 'all';
  final _scrollController = ScrollController();

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
    try {
      // Fetch logs from API
      final client = ApiClient();
      final response = await client.get('/api/v1/logs?level=$_filter&limit=100');
      if (response != null && response is List) {
        setState(() {
          _logs.clear();
          _logs.addAll(response.map((e) => LogEntry.fromJson(e)).toList());
        });
      }
    } catch (e) {
      // Generate sample logs for offline mode
      setState(() {
        _logs.clear();
        _logs.add(LogEntry(
          timestamp: DateTime.now(),
          level: 'info',
          message: 'Log viewer ready (API not connected)',
        ));
      });
    } finally {
      setState(() => _loading = false);
    }
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
                      Icon(Icons.article_outlined, size: 48.sp, color: Colors.grey),
                      SizedBox(height: 8.h),
                      const Text('No logs', style: TextStyle(color: Colors.grey)),
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

  LogEntry({required this.timestamp, required this.level, required this.message});

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      level: json['level'] ?? 'info',
      message: json['message'] ?? '',
    );
  }
}
