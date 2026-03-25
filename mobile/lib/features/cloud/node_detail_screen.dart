import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'cloud_models.dart';

class NodeDetailScreen extends StatelessWidget {
  final CloudInstance node;

  const NodeDetailScreen({Key? key, required this.node}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(node.label.isNotEmpty ? node.label : (node.ipv4 ?? 'node')),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy All Links',
            onPressed: () => _copyAllLinks(context),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(16.w),
        children: [
          _buildInfoCard(context),
          SizedBox(height: 16.h),
          if (_nodeInfo.ssPort > 0)
            _buildProtocolCard(
                context, 'Shadowsocks', Icons.lock, _ssDetails()),
          if (_nodeInfo.hyPort > 0)
            _buildProtocolCard(
                context, 'Hysteria2', Icons.speed, _hysteriaDetails()),
          if (_nodeInfo.vlessPort > 0)
            _buildProtocolCard(
                context, 'VLESS-Reality', Icons.shield, _vlessDetails()),
          if (_nodeInfo.trojanPort > 0)
            _buildProtocolCard(
                context, 'Trojan', Icons.security, _trojanDetails()),
        ],
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Node Info', style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 12.h),
            _infoRow('IP', node.ipv4 ?? ''),
            if ((node.ipv6 ?? '').isNotEmpty) _infoRow('IPv6', node.ipv6!),
            _infoRow('Region', node.region),
            _infoRow('Status', node.status),
            _infoRow('Created', node.createdAt?.toIso8601String() ?? '-'),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolCard(BuildContext context, String name, IconData icon,
      List<_DetailRow> details) {
    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(name),
        initiallyExpanded: true,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
            child: Column(
              children: details
                  .map((d) => _copyableRow(context, d.label, d.value))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          SizedBox(
              width: 80.w,
              child: Text(label,
                  style: TextStyle(color: Colors.grey, fontSize: 13.sp))),
          Expanded(child: Text(value, style: TextStyle(fontSize: 13.sp))),
        ],
      ),
    );
  }

  Widget _copyableRow(BuildContext context, String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          SizedBox(
              width: 80.w,
              child: Text(label,
                  style: TextStyle(color: Colors.grey, fontSize: 12.sp))),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 12.sp, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: Icon(Icons.copy, size: 16.sp),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('$label copied'),
                    duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }

  List<_DetailRow> _ssDetails() => [
        _DetailRow('Port', '${_nodeInfo.ssPort}'),
        _DetailRow('Password', _nodeInfo.ssPassword),
        _DetailRow('Method', 'aes-256-gcm'),
      ];

  List<_DetailRow> _hysteriaDetails() => [
        _DetailRow('Port', '${_nodeInfo.hyPort}'),
        _DetailRow('Password', _nodeInfo.hyPassword),
        _DetailRow('SNI', _nodeInfo.hyServerName),
      ];

  List<_DetailRow> _vlessDetails() => [
        _DetailRow('Port', '${_nodeInfo.vlessPort}'),
        _DetailRow('UUID', _nodeInfo.vlessUuid),
        _DetailRow('Public Key', _nodeInfo.vlessPublicKey),
        _DetailRow('Short ID', _nodeInfo.vlessShortId),
        _DetailRow('SNI', _nodeInfo.vlessServerName),
      ];

  List<_DetailRow> _trojanDetails() => [
        _DetailRow('Port', '${_nodeInfo.trojanPort}'),
        _DetailRow('Password', _nodeInfo.trojanPassword),
        _DetailRow('SNI', _nodeInfo.trojanServerName),
      ];

  void _copyAllLinks(BuildContext context) {
    final links = <String>[];
    if (_nodeInfo.ssPort > 0 && node.ipv4 != null) {
      final ssCredential = _buildShadowsocksLink();
      if (ssCredential != null) {
        links.add(ssCredential);
      }
    }
    if (_nodeInfo.hyPort > 0 && node.ipv4 != null) {
      links.add(
          'hysteria2://${_nodeInfo.hyPassword}@${node.ipv4!}:${_nodeInfo.hyPort}');
    }
    if (_nodeInfo.vlessPort > 0 && node.ipv4 != null) {
      links.add(
          'vless://${_nodeInfo.vlessUuid}@${node.ipv4!}:${_nodeInfo.vlessPort}');
    }
    if (_nodeInfo.trojanPort > 0 && node.ipv4 != null) {
      links.add(
          'trojan://${_nodeInfo.trojanPassword}@${node.ipv4!}:${_nodeInfo.trojanPort}');
    }

    Clipboard.setData(ClipboardData(text: links.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${links.length} links copied')),
    );
  }

  String? _buildShadowsocksLink() {
    if (node.ipv4 == null || node.ipv4!.isEmpty) {
      return null;
    }

    final password = _nodeInfo.ssPassword;
    if (password.isEmpty) {
      return null;
    }

    final method = 'aes-256-gcm';
    final userInfo = base64Encode(utf8.encode('$method:$password'));
    return 'ss://$userInfo@${node.ipv4!}:${_nodeInfo.ssPort}';
  }

  NodeInfo get _nodeInfo =>
      node.nodeInfo ??
      const NodeInfo(
        ssPort: 0,
        ssPassword: '',
        hyPort: 0,
        hyPassword: '',
        hyServerName: '',
        hyInsecure: null,
        vlessPort: 0,
        vlessUuid: '',
        vlessPublicKey: '',
        vlessShortId: '',
        vlessServerName: '',
        trojanPort: 0,
        trojanPassword: '',
        trojanServerName: '',
        trojanInsecure: null,
      );
}

class _DetailRow {
  final String label;
  final String value;
  _DetailRow(this.label, this.value);
}
