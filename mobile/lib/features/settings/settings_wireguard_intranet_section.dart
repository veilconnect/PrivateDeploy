import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import 'app_settings_provider.dart';

/// Opens the intranet-WireGuard config form and persists the result. Shared by
/// the settings section and the home-screen WireGuard card so both edit the
/// same independent overlay.
Future<void> showWireguardIntranetConfigDialog(BuildContext context) async {
  final settings = context.read<AppSettingsProvider>();
  final result = await showDialog<WireGuardIntranet>(
    context: context,
    builder: (_) => _WireguardIntranetDialog(current: settings.wireGuardIntranet),
  );
  if (result != null) {
    await settings.setWireGuardIntranet(result);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('内网 WireGuard 已保存 / Intranet WireGuard saved'),
        ),
      );
    }
  }
}

/// Independent "Intranet VPN (WireGuard)" control. This is deliberately a
/// SEPARATE section from the proxy node list: WireGuard here only carries LAN
/// traffic (to reach a home/office network), runs alongside the 网络访问 proxy
/// nodes inside the same tunnel, and has its own on/off switch. See
/// [WireGuardIntranet] and the `_applyWireGuardIntranet` overlay.
class SettingsWireguardIntranetSection extends StatelessWidget {
  const SettingsWireguardIntranetSection({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsProvider>();
    final wg = settings.wireGuardIntranet;
    final cidrs = wg.intranetCidrs;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lan_outlined, size: 20.sp),
                SizedBox(width: 8.w),
                Expanded(
                  child: Text(
                    '内网 VPN (WireGuard) / Intranet VPN',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            SizedBox(height: 4.h),
            Text(
              '独立于网络访问节点:只把内网流量(局域网)走 WireGuard,与代理节点同时运行、互不影响。\n'
              'Runs alongside the proxy nodes; only LAN traffic goes through WireGuard.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SizedBox(height: 8.h),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用内网 VPN / Enable intranet VPN'),
              subtitle: Text(
                wg.isConfigured
                    ? (cidrs.isEmpty
                        ? '已配置 / Configured'
                        : '走 WireGuard 的网段 / Routed: ${cidrs.join(', ')}')
                    : '尚未配置,点下方按钮设置 / Not configured yet',
              ),
              value: wg.enabled,
              onChanged: wg.isConfigured
                  ? (value) async {
                      await settings.setWireGuardIntranetEnabled(value);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              '已保存,重新连接后生效 / Saved — reconnect to apply',
                            ),
                          ),
                        );
                      }
                    }
                  : null,
            ),
            SizedBox(height: 4.h),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.tune),
                label: Text(wg.isConfigured
                    ? '编辑 WireGuard 配置 / Edit'
                    : '配置 WireGuard / Configure'),
                onPressed: () => showWireguardIntranetConfigDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

class _WireguardIntranetDialog extends StatefulWidget {
  const _WireguardIntranetDialog({required this.current});

  final WireGuardIntranet current;

  @override
  State<_WireguardIntranetDialog> createState() =>
      _WireguardIntranetDialogState();
}

class _WireguardIntranetDialogState extends State<_WireguardIntranetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _server;
  late final TextEditingController _port;
  late final TextEditingController _privateKey;
  late final TextEditingController _peerPublicKey;
  late final TextEditingController _localAddress;
  late final TextEditingController _extraCidrs;
  late final TextEditingController _preSharedKey;
  late final TextEditingController _mtu;
  late final TextEditingController _keepalive;

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    _server = TextEditingController(text: c.server);
    _port = TextEditingController(text: c.serverPort > 0 ? '${c.serverPort}' : '');
    _privateKey = TextEditingController(text: c.privateKey);
    _peerPublicKey = TextEditingController(text: c.peerPublicKey);
    _localAddress = TextEditingController(text: c.localAddress.join(', '));
    _extraCidrs = TextEditingController(text: c.extraCidrs.join(', '));
    _preSharedKey = TextEditingController(text: c.preSharedKey ?? '');
    _mtu = TextEditingController(text: c.mtu != null ? '${c.mtu}' : '');
    _keepalive = TextEditingController(text: '${c.persistentKeepalive}');
  }

  @override
  void dispose() {
    for (final ctrl in [
      _server,
      _port,
      _privateKey,
      _peerPublicKey,
      _localAddress,
      _extraCidrs,
      _preSharedKey,
      _mtu,
      _keepalive,
    ]) {
      ctrl.dispose();
    }
    super.dispose();
  }

  List<String> _splitList(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  /// Every entry must be a parseable IPv4/IPv6 address or CIDR. An invalid
  /// entry is silently dropped by [WireGuardIntranet.intranetCidrs] later —
  /// which can leave the overlay with NOTHING to route and yield a tunnel
  /// that looks connected but never carries the LAN. Reject it here instead.
  String? _validateCidrList(String? v, {required bool required}) {
    final entries = _splitList(v ?? '');
    if (entries.isEmpty) {
      return required ? '必填 / Required' : null;
    }
    for (final entry in entries) {
      if (wireGuardCidrNetwork(entry) == null) {
        return '无效地址: $entry / Invalid address';
      }
    }
    return null;
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool required = false,
    bool obscure = false,
    TextInputType? keyboard,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12.h),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        validator: validator ??
            (required
                ? (v) =>
                    (v == null || v.trim().isEmpty) ? '必填 / Required' : null
                : null),
      ),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('端口无效 / Invalid port')),
      );
      return;
    }
    final psk = _preSharedKey.text.trim();
    final mtu = int.tryParse(_mtu.text.trim());
    // Keepalive: blank/garbage -> the 25s default (don't silently disable NAT
    // refresh on a typo); a negative is clamped to 0 = explicit opt-out.
    final keepaliveText = _keepalive.text.trim();
    final keepalive = keepaliveText.isEmpty
        ? 25
        : (int.tryParse(keepaliveText) ?? 25).clamp(0, 65535);
    final wg = widget.current.copyWith(
      server: _server.text.trim(),
      serverPort: port,
      privateKey: _privateKey.text.trim(),
      peerPublicKey: _peerPublicKey.text.trim(),
      localAddress: _splitList(_localAddress.text),
      extraCidrs: _splitList(_extraCidrs.text),
      preSharedKey: psk.isEmpty ? null : psk,
      clearPreSharedKey: psk.isEmpty,
      mtu: (mtu != null && mtu > 0) ? mtu : null,
      clearMtu: !(mtu != null && mtu > 0),
      persistentKeepalive: keepalive,
    );
    Navigator.pop(context, wg);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('内网 WireGuard / Intranet WireGuard'),
      content: SizedBox(
        width: 420.w,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(_server, '服务器地址 / Server',
                    hint: 'wg.example.com', required: true),
                _field(_port, '端口 / Port',
                    hint: '51820',
                    required: true,
                    keyboard: TextInputType.number),
                _field(_privateKey, '本地私钥 / Private key',
                    required: true, obscure: true),
                _field(_peerPublicKey, '对端公钥 / Peer public key',
                    required: true),
                _field(_localAddress, '本地地址 / Local address',
                    hint: '10.8.0.2/24',
                    validator: (v) => _validateCidrList(v, required: true)),
                _field(_extraCidrs, '额外内网网段 / Extra LAN CIDRs (可选)',
                    hint: '192.168.1.0/24, 10.0.0.0/8',
                    maxLines: 2,
                    validator: (v) => _validateCidrList(v, required: false)),
                _field(_preSharedKey, '预共享密钥 / Pre-shared key (可选)',
                    obscure: true),
                _field(_mtu, 'MTU (可选)',
                    keyboard: TextInputType.number,
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return null;
                      final n = int.tryParse(t);
                      return (n == null || n < 576 || n > 9000)
                          ? '576–9000 或留空 / 576–9000 or blank'
                          : null;
                    }),
                _field(_keepalive, '保活间隔秒 / Keepalive',
                    keyboard: TextInputType.number),
                Text(
                  '提示:本地地址所在子网会自动走 WireGuard,额外网段可叠加。其余流量仍走网络访问/直连。\n'
                  'The local-address subnet is auto-routed; the rest keeps using proxy/direct.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消 / Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存 / Save'),
        ),
      ],
    );
  }
}
