import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import 'cloud_models.dart';

class NodeDetailScreen extends StatelessWidget {
  final CloudInstance node;

  const NodeDetailScreen({Key? key, required this.node}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(node.label.isNotEmpty ? node.label : (node.ipv4 ?? 'node')),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: l10n.copyAllLinks,
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
                context, l10n.shadowsocks, Icons.lock, _ssDetails(l10n)),
          if (_nodeInfo.hyPort > 0)
            _buildProtocolCard(
                context, l10n.hysteria2, Icons.speed, _hysteriaDetails(l10n)),
          if (_nodeInfo.vlessPort > 0)
            _buildProtocolCard(
                context, l10n.vlessReality, Icons.shield, _vlessDetails(l10n)),
          if (_nodeInfo.trojanPort > 0)
            _buildProtocolCard(
                context, l10n.trojan, Icons.security, _trojanDetails(l10n)),
        ],
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.nodeInfo, style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 12.h),
            _infoRow(l10n.ip, node.ipv4 ?? ''),
            if ((node.ipv6 ?? '').isNotEmpty) _infoRow(l10n.ipv6, node.ipv6!),
            _infoRow(l10n.region, node.region),
            _infoRow(l10n.statusLabel, node.status),
            _infoRow(l10n.created, node.createdAt?.toIso8601String() ?? '-'),
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
                    content: Text(AppLocalizations.of(context)!.labelCopied(label)),
                    duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }

  List<_DetailRow> _ssDetails(AppLocalizations l10n) => [
        _DetailRow(l10n.port, '${_nodeInfo.ssPort}'),
        _DetailRow(l10n.password, _nodeInfo.ssPassword),
        _DetailRow(l10n.method, 'aes-256-gcm'),
      ];

  List<_DetailRow> _hysteriaDetails(AppLocalizations l10n) => [
        _DetailRow(l10n.port, '${_nodeInfo.hyPort}'),
        _DetailRow(l10n.password, _nodeInfo.hyPassword),
        _DetailRow(l10n.sni, _nodeInfo.hyServerName),
      ];

  List<_DetailRow> _vlessDetails(AppLocalizations l10n) => [
        _DetailRow(l10n.port, '${_nodeInfo.vlessPort}'),
        _DetailRow(l10n.uuid, _nodeInfo.vlessUuid),
        _DetailRow(l10n.publicKey, _nodeInfo.vlessPublicKey),
        _DetailRow(l10n.shortId, _nodeInfo.vlessShortId),
        _DetailRow(l10n.sni, _nodeInfo.vlessServerName),
      ];

  List<_DetailRow> _trojanDetails(AppLocalizations l10n) => [
        _DetailRow(l10n.port, '${_nodeInfo.trojanPort}'),
        _DetailRow(l10n.password, _nodeInfo.trojanPassword),
        _DetailRow(l10n.sni, _nodeInfo.trojanServerName),
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
      final sni = _nodeInfo.hyServerName.isNotEmpty
          ? _nodeInfo.hyServerName
          : node.ipv4!;
      // Cloud nodes use self-signed certs; default to insecure=true
      final insecure = (_nodeInfo.hyInsecure ?? true) ? '1' : '0';
      links.add(
          'hysteria2://${_nodeInfo.hyPassword}@${node.ipv4!}:${_nodeInfo.hyPort}'
          '?sni=${Uri.encodeComponent(sni)}&insecure=$insecure'
          '&up_mbps=100&down_mbps=100'
          '#${Uri.encodeComponent('Hy2 ${node.ipv4}')}');
    }
    if (_nodeInfo.vlessPort > 0 && node.ipv4 != null) {
      // Reality protocol needs a real domain as SNI, not the server IP
      final sni = _nodeInfo.vlessServerName.isNotEmpty
          ? _nodeInfo.vlessServerName
          : 'www.microsoft.com';
      final params = <String>[
        'security=reality',
        'sni=${Uri.encodeComponent(sni)}',
        'fp=chrome',
        'type=tcp',
        if (_nodeInfo.vlessPublicKey.isNotEmpty)
          'pbk=${Uri.encodeComponent(_nodeInfo.vlessPublicKey)}',
        if (_nodeInfo.vlessShortId.isNotEmpty)
          'sid=${Uri.encodeComponent(_nodeInfo.vlessShortId)}',
        'flow=xtls-rprx-vision',
      ];
      links.add(
          'vless://${_nodeInfo.vlessUuid}@${node.ipv4!}:${_nodeInfo.vlessPort}'
          '?${params.join('&')}'
          '#${Uri.encodeComponent('VLESS ${node.ipv4}')}');
    }
    if (_nodeInfo.trojanPort > 0 && node.ipv4 != null) {
      final sni = _nodeInfo.trojanServerName.isNotEmpty
          ? _nodeInfo.trojanServerName
          : node.ipv4!;
      // Cloud nodes use self-signed certs; default to insecure=true
      final insecure = (_nodeInfo.trojanInsecure ?? true) ? '1' : '0';
      links.add(
          'trojan://${_nodeInfo.trojanPassword}@${node.ipv4!}:${_nodeInfo.trojanPort}'
          '?sni=${Uri.encodeComponent(sni)}&insecure=$insecure'
          '#${Uri.encodeComponent('Trojan ${node.ipv4}')}');
    }

    Clipboard.setData(ClipboardData(text: links.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.linksCopied(links.length))),
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
    return 'ss://$userInfo@${node.ipv4!}:${_nodeInfo.ssPort}'
        '#${Uri.encodeComponent('SS ${node.ipv4}')}';

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
