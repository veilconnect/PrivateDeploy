import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/security/encrypted_share.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/share_passphrase_dialog.dart';
import 'cloud_models.dart';

class NodeDetailScreen extends StatelessWidget {
  final CloudInstance node;

  const NodeDetailScreen({Key? key, required this.node}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final protocolSections = _protocolSections(l10n);
    return Scaffold(
      appBar: AppBar(
        title: Text(node.label.isNotEmpty ? node.label : (node.ipv4 ?? 'node')),
      ),
      body: ListView(
        padding: EdgeInsets.all(16.w),
        children: [
          _buildInfoCard(context, protocolSections),
          SizedBox(height: 16.h),
          ...protocolSections
              .map((section) => _buildProtocolCard(context, section)),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    List<_ProtocolSection> protocolSections,
  ) {
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
            if (protocolSections.isNotEmpty) ...[
              SizedBox(height: 12.h),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => _copyAllLinks(context),
                  icon: const Icon(Icons.copy_all),
                  label: Text(l10n.copyAllLinks),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolCard(BuildContext context, _ProtocolSection section) {
    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: ExpansionTile(
        leading: Icon(section.icon),
        title: Text(section.name),
        initiallyExpanded: true,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _copyProtocol(context, section),
                    icon: const Icon(Icons.copy),
                    label: Text(
                      AppLocalizations.of(context)!
                          .copyProtocolLink(section.name),
                    ),
                  ),
                ),
                SizedBox(height: 12.h),
                ...section.details.map((d) => _detailRow(d.label, d.value)),
              ],
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

  Widget _detailRow(String label, String value) {
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

  List<_ProtocolSection> _protocolSections(AppLocalizations l10n) {
    final sections = <_ProtocolSection>[];
    final shadowsocksLink = _buildShadowsocksLink();
    if (shadowsocksLink != null) {
      sections.add(
        _ProtocolSection(
          name: l10n.shadowsocks,
          icon: Icons.lock,
          link: shadowsocksLink,
          details: _ssDetails(l10n),
        ),
      );
    }
    final hysteriaLink = _buildHysteria2Link();
    if (hysteriaLink != null) {
      sections.add(
        _ProtocolSection(
          name: l10n.hysteria2,
          icon: Icons.speed,
          link: hysteriaLink,
          details: _hysteriaDetails(l10n),
        ),
      );
    }
    final vlessLink = _buildVlessLink();
    if (vlessLink != null) {
      sections.add(
        _ProtocolSection(
          name: l10n.vlessReality,
          icon: Icons.shield,
          link: vlessLink,
          details: _vlessDetails(l10n),
        ),
      );
    }
    final trojanLink = _buildTrojanLink();
    if (trojanLink != null) {
      sections.add(
        _ProtocolSection(
          name: l10n.trojan,
          icon: Icons.security,
          link: trojanLink,
          details: _trojanDetails(l10n),
        ),
      );
    }
    return sections;
  }

  Future<void> _copyAllLinks(BuildContext context) async {
    final links = [
      _buildShadowsocksLink(),
      _buildHysteria2Link(),
      _buildVlessLink(),
      _buildTrojanLink(),
    ].whereType<String>().toList();
    if (links.isEmpty) {
      return;
    }

    await _copyEncryptedPayload(
      context,
      kind: EncryptedShareKind.proxyLinks,
      content: links.join('\n'),
      label: node.label.isNotEmpty ? node.label : (node.ipv4 ?? 'node'),
      message: AppLocalizations.of(context)!.encryptedNodeCopied,
    );
  }

  Future<void> _copyProtocol(
    BuildContext context,
    _ProtocolSection section,
  ) {
    return _copyEncryptedPayload(
      context,
      kind: EncryptedShareKind.proxyLinks,
      content: section.link,
      label:
          '${node.label.isNotEmpty ? node.label : (node.ipv4 ?? 'node')} · ${section.name}',
      message: AppLocalizations.of(context)!.encryptedProtocolCopied(
        section.name,
      ),
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

  String? _buildHysteria2Link() {
    if (_nodeInfo.hyPort <= 0 || node.ipv4 == null || node.ipv4!.isEmpty) {
      return null;
    }
    final sni =
        _nodeInfo.hyServerName.isNotEmpty ? _nodeInfo.hyServerName : node.ipv4!;
    final insecure = (_nodeInfo.hyInsecure ?? true) ? '1' : '0';
    return 'hysteria2://${_nodeInfo.hyPassword}@${node.ipv4!}:${_nodeInfo.hyPort}'
        '?sni=${Uri.encodeComponent(sni)}&insecure=$insecure'
        '&up_mbps=100&down_mbps=100'
        '#${Uri.encodeComponent('Hy2 ${node.ipv4}')}';
  }

  String? _buildVlessLink() {
    if (_nodeInfo.vlessPort <= 0 || node.ipv4 == null || node.ipv4!.isEmpty) {
      return null;
    }
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
    return 'vless://${_nodeInfo.vlessUuid}@${node.ipv4!}:${_nodeInfo.vlessPort}'
        '?${params.join('&')}'
        '#${Uri.encodeComponent('VLESS ${node.ipv4}')}';
  }

  String? _buildTrojanLink() {
    if (_nodeInfo.trojanPort <= 0 || node.ipv4 == null || node.ipv4!.isEmpty) {
      return null;
    }
    final sni = _nodeInfo.trojanServerName.isNotEmpty
        ? _nodeInfo.trojanServerName
        : node.ipv4!;
    final insecure = (_nodeInfo.trojanInsecure ?? true) ? '1' : '0';
    return 'trojan://${_nodeInfo.trojanPassword}@${node.ipv4!}:${_nodeInfo.trojanPort}'
        '?sni=${Uri.encodeComponent(sni)}&insecure=$insecure'
        '#${Uri.encodeComponent('Trojan ${node.ipv4}')}';
  }

  Future<void> _copyEncryptedPayload(
    BuildContext context, {
    required String kind,
    required String content,
    required String message,
    String? label,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final passphrase = await showSharePassphraseDialog(
      context: context,
      title: l10n.encryptBeforeCopyTitle,
      message: l10n.encryptBeforeCopyMessage,
    );
    if (passphrase == null || !context.mounted) {
      return;
    }

    try {
      final armored = await EncryptedShareCodec.encrypt(
        kind: kind,
        content: content,
        passphrase: passphrase,
        label: label,
      );
      await Clipboard.setData(ClipboardData(text: armored));
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
    } catch (e) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.encryptedCopyFailed('$e')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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

class _ProtocolSection {
  final String name;
  final IconData icon;
  final String link;
  final List<_DetailRow> details;

  const _ProtocolSection({
    required this.name,
    required this.icon,
    required this.link,
    required this.details,
  });
}
