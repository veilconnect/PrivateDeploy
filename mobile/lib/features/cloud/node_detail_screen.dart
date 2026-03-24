import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'cloud_models.dart';

class NodeDetailScreen extends StatelessWidget {
  final CloudNode node;

  const NodeDetailScreen({Key? key, required this.node}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(node.label.isNotEmpty ? node.label : node.ipv4),
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
          if (node.ssPort > 0) _buildProtocolCard(context, 'Shadowsocks', Icons.lock, _ssDetails()),
          if (node.hysteriaPort > 0) _buildProtocolCard(context, 'Hysteria2', Icons.speed, _hysteriaDetails()),
          if (node.vlessPort > 0) _buildProtocolCard(context, 'VLESS-Reality', Icons.shield, _vlessDetails()),
          if (node.trojanPort > 0) _buildProtocolCard(context, 'Trojan', Icons.security, _trojanDetails()),
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
            _infoRow('IP', node.ipv4),
            if (node.ipv6.isNotEmpty) _infoRow('IPv6', node.ipv6),
            _infoRow('Region', node.region),
            _infoRow('Status', node.status),
            _infoRow('Created', node.createdAt),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolCard(BuildContext context, String name, IconData icon, List<_DetailRow> details) {
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
              children: details.map((d) => _copyableRow(context, d.label, d.value)).toList(),
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
          SizedBox(width: 80.w, child: Text(label, style: TextStyle(color: Colors.grey, fontSize: 13.sp))),
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
          SizedBox(width: 80.w, child: Text(label, style: TextStyle(color: Colors.grey, fontSize: 12.sp))),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 12.sp, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: Icon(Icons.copy, size: 16.sp),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }

  List<_DetailRow> _ssDetails() => [
    _DetailRow('Port', '${node.ssPort}'),
    _DetailRow('Password', node.ssPassword),
    _DetailRow('Method', 'aes-256-gcm'),
  ];

  List<_DetailRow> _hysteriaDetails() => [
    _DetailRow('Port', '${node.hysteriaPort}'),
    _DetailRow('Password', node.hysteriaPassword),
    _DetailRow('SNI', node.hysteriaServerName),
  ];

  List<_DetailRow> _vlessDetails() => [
    _DetailRow('Port', '${node.vlessPort}'),
    _DetailRow('UUID', node.vlessUUID),
    _DetailRow('Public Key', node.vlessPublicKey),
    _DetailRow('Short ID', node.vlessShortId),
    _DetailRow('SNI', node.vlessServerName),
  ];

  List<_DetailRow> _trojanDetails() => [
    _DetailRow('Port', '${node.trojanPort}'),
    _DetailRow('Password', node.trojanPassword),
    _DetailRow('SNI', node.trojanServerName),
  ];

  void _copyAllLinks(BuildContext context) {
    final links = <String>[];
    if (node.ssPort > 0) links.add('ss://...@${node.ipv4}:${node.ssPort}');
    if (node.hysteriaPort > 0) links.add('hysteria2://${node.hysteriaPassword}@${node.ipv4}:${node.hysteriaPort}');
    if (node.vlessPort > 0) links.add('vless://${node.vlessUUID}@${node.ipv4}:${node.vlessPort}');
    if (node.trojanPort > 0) links.add('trojan://${node.trojanPassword}@${node.ipv4}:${node.trojanPort}');

    Clipboard.setData(ClipboardData(text: links.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${links.length} links copied')),
    );
  }
}

class _DetailRow {
  final String label;
  final String value;
  _DetailRow(this.label, this.value);
}
