enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Refines `VpnStatus.connected` with what the native side observed when it
/// probed the upstream. `healthy` is silent; `degraded` carries a non-empty
/// status message ("upstream blocked, switch nodes" or "egress unverified")
/// that the UI must surface honestly rather than collapsing to a green
/// "connected" badge. Only meaningful when `VpnStatus == connected`.
enum VpnHealth {
  healthy,
  degraded,
}

class TrafficStats {
  final int uploadBytes;
  final int downloadBytes;
  final double uploadSpeed;
  final double downloadSpeed;
  final Duration connectionTime;

  TrafficStats({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.connectionTime,
  });

  factory TrafficStats.zero() {
    return TrafficStats(
      uploadBytes: 0,
      downloadBytes: 0,
      uploadSpeed: 0,
      downloadSpeed: 0,
      connectionTime: Duration.zero,
    );
  }

  int get totalBytes => uploadBytes + downloadBytes;

  TrafficStats copyWith({
    int? uploadBytes,
    int? downloadBytes,
    double? uploadSpeed,
    double? downloadSpeed,
    Duration? connectionTime,
  }) {
    return TrafficStats(
      uploadBytes: uploadBytes ?? this.uploadBytes,
      downloadBytes: downloadBytes ?? this.downloadBytes,
      uploadSpeed: uploadSpeed ?? this.uploadSpeed,
      downloadSpeed: downloadSpeed ?? this.downloadSpeed,
      connectionTime: connectionTime ?? this.connectionTime,
    );
  }

  String get uploadFormatted => _formatBytes(uploadBytes);
  String get downloadFormatted => _formatBytes(downloadBytes);
  String get totalFormatted => _formatBytes(totalBytes);
  String get uploadSpeedFormatted => '${_formatBytes(uploadSpeed.toInt())}/s';
  String get downloadSpeedFormatted =>
      '${_formatBytes(downloadSpeed.toInt())}/s';

  String get connectionTimeFormatted {
    final hours = connectionTime.inHours;
    final minutes = connectionTime.inMinutes % 60;
    final seconds = connectionTime.inSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}
