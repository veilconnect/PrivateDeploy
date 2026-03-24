import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({Key? key}) : super(key: key);

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  final List<SpeedTestResult> _results = [];
  bool _testing = false;
  String _status = 'Ready';

  final _testTargets = [
    _TestTarget('Google', 'www.google.com', 443),
    _TestTarget('GitHub', 'github.com', 443),
    _TestTarget('Cloudflare', '1.1.1.1', 443),
    _TestTarget('OpenAI', 'api.openai.com', 443),
    _TestTarget('Anthropic', 'api.anthropic.com', 443),
  ];

  Future<void> _runSpeedTest() async {
    setState(() {
      _testing = true;
      _results.clear();
      _status = 'Testing...';
    });

    for (final target in _testTargets) {
      if (!_testing) break;
      setState(() => _status = 'Testing ${target.name}...');

      final result = await _testLatency(target);
      setState(() => _results.add(result));
    }

    setState(() {
      _testing = false;
      _status = 'Complete';
    });
  }

  Future<SpeedTestResult> _testLatency(_TestTarget target) async {
    final stopwatch = Stopwatch()..start();
    bool success = false;
    String error = '';

    try {
      final socket = await Socket.connect(
        target.host,
        target.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      success = true;
    } on SocketException catch (e) {
      error = e.message;
    } on TimeoutException {
      error = 'Timeout';
    } catch (e) {
      error = e.toString();
    }

    stopwatch.stop();

    return SpeedTestResult(
      name: target.name,
      host: target.host,
      latencyMs: success ? stopwatch.elapsedMilliseconds : -1,
      success: success,
      error: error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Speed Test')),
      body: Column(
        children: [
          // Status & Start button
          Padding(
            padding: EdgeInsets.all(16.w),
            child: Column(
              children: [
                Text(_status, style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: 12.h),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _testing ? null : _runSpeedTest,
                    icon: Icon(_testing ? Icons.hourglass_top : Icons.speed),
                    label: Text(_testing ? 'Testing...' : 'Start Speed Test'),
                  ),
                ),
              ],
            ),
          ),

          if (_testing) const LinearProgressIndicator(),

          // Results
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed, size: 48.sp, color: Colors.grey),
                        SizedBox(height: 8.h),
                        const Text('Tap Start to test latency', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) => _buildResultTile(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(SpeedTestResult result) {
    final color = !result.success
        ? Colors.red
        : result.latencyMs < 200
            ? Colors.green
            : result.latencyMs < 500
                ? Colors.orange
                : Colors.red;

    return ListTile(
      leading: Icon(
        result.success ? Icons.check_circle : Icons.error,
        color: color,
      ),
      title: Text(result.name),
      subtitle: Text(result.host, style: TextStyle(fontSize: 12.sp, color: Colors.grey)),
      trailing: Text(
        result.success ? '${result.latencyMs}ms' : result.error,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 14.sp,
        ),
      ),
    );
  }
}

class SpeedTestResult {
  final String name;
  final String host;
  final int latencyMs;
  final bool success;
  final String error;

  SpeedTestResult({
    required this.name,
    required this.host,
    required this.latencyMs,
    required this.success,
    this.error = '',
  });
}

class _TestTarget {
  final String name;
  final String host;
  final int port;
  _TestTarget(this.name, this.host, this.port);
}
