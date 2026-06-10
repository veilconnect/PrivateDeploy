import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../settings/app_settings_provider.dart';
import '../settings/settings_wireguard_intranet_section.dart';
import '../vpn/vpn_provider.dart';

/// Home-screen control for the independent intranet WireGuard tunnel. It sits
/// next to the main connect card and lets the user turn the LAN tunnel on/off
/// directly — separate from the proxy node selection. Toggling applies live:
/// the caller (nodes screen) reconnects the VPN so the overlay merges in/out.
class NodesWireguardCard extends StatelessWidget {
  const NodesWireguardCard({
    Key? key,
    required this.onSetEnabled,
    this.busy = false,
    this.proxyActive = false,
  }) : super(key: key);

  /// Persists the enabled flag and applies it (reconnect if running, otherwise
  /// start the tunnel). Implemented by the nodes screen which owns the VPN
  /// connect/restart handlers.
  final Future<void> Function(bool enabled) onSetEnabled;

  /// When true the switch is disabled (a connect/restart is in flight).
  final bool busy;

  /// Whether the proxy (网络访问) node is the active tunnel. Used to tell apart
  /// proxy+WG from WireGuard-only: in WG-only mode the proxy-oriented "connected"
  /// status doesn't fire, but the tunnel (and WireGuard) are live.
  final bool proxyActive;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsProvider>();
    final vpn = context.watch<VpnProvider>();
    final wg = settings.wireGuardIntranet;
    final cidrs = wg.intranetCidrs;
    // WireGuard is "running" whenever it's enabled and its traffic is actually
    // in the tunnel. That's true when the proxy+WG tunnel is connected, OR when
    // the tunnel is up carrying only WireGuard (proxy disconnected) — the latter
    // doesn't reach the proxy-oriented "connected" status, so detect it via
    // "no proxy active + tunnel not down".
    final tunnelLive = vpn.status != VpnStatus.disconnected;
    final running =
        wg.enabled && (vpn.isConnected || (!proxyActive && tunnelLive));
    final theme = Theme.of(context);

    final Color? accent = running ? Colors.green : null;
    final String status;
    if (!wg.isConfigured) {
      status = '未配置 — 点下方按钮设置内网 WireGuard\nNot configured yet';
    } else if (!wg.enabled) {
      status = '已关闭 / Off';
    } else if (running) {
      status = '内网已连接 · 走 ${cidrs.join(', ')}\nConnected — LAN via WireGuard';
    } else {
      status = '已启用,主连接建立后生效 / Enabled — applies once the VPN is up';
    }

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(running ? Icons.lan : Icons.lan_outlined,
                    size: 22.sp, color: accent),
                SizedBox(width: 8.w),
                Expanded(
                  child: Text(
                    '内网 VPN (WireGuard)',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (busy)
                  SizedBox(
                    width: 20.w,
                    height: 20.w,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    value: wg.enabled,
                    onChanged: wg.isConfigured
                        ? (value) => onSetEnabled(value)
                        : null,
                  ),
              ],
            ),
            SizedBox(height: 4.h),
            Text(status, style: theme.textTheme.bodySmall?.copyWith(color: accent)),
            SizedBox(height: 4.h),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.tune, size: 18),
                label: Text(wg.isConfigured
                    ? '编辑配置 / Edit'
                    : '配置 WireGuard / Configure'),
                onPressed: busy
                    ? null
                    : () => showWireguardIntranetConfigDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
