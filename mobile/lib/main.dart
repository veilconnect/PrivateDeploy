import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'l10n/app_localizations.dart';

import 'core/storage/storage_service.dart';
import 'features/home/home_screen.dart';
import 'features/profiles/bundled_rule_set_registry.dart';
import 'features/profiles/profile_provider.dart';
import 'features/settings/app_settings_provider.dart';
import 'features/vpn/vpn_provider.dart';
import 'features/cloud/cloud_node_config_builder.dart' show CdnEndpoint;
import 'features/cloud/cloud_models.dart' show CloudInstance;
import 'features/cloud/cloud_provider.dart';
import 'features/nodes/nodes_vpn_actions.dart' show autoFailoverToNextCloudNode;
import 'features/cdn/cdn_provider.dart';
import 'shared/utils/global_messenger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();

  // Initialize Storage
  await StorageService.init();

  // Install bundled routing rule sets before the app starts so the first VPN
  // connection can immediately apply CN split-routing rules.
  await BundledRuleSetRegistry.ensureInstalled();

  final appSettingsProvider = AppSettingsProvider();
  await appSettingsProvider.ready;

  runApp(PrivateDeployApp(appSettingsProvider: appSettingsProvider));
}

class PrivateDeployApp extends StatelessWidget {
  const PrivateDeployApp({Key? key, this.appSettingsProvider})
      : super(key: key);

  final AppSettingsProvider? appSettingsProvider;

  @override
  Widget build(BuildContext context) {
    final appSettings = appSettingsProvider;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProfileProvider()),
        ChangeNotifierProvider(create: (_) => CloudProvider()),
        // AppSettingsProvider is created BEFORE the VpnProvider proxy so the
        // auto-failover handler below can read the current routing settings
        // (it must re-apply the WireGuard overlay / custom rules to each
        // failover node's config). The real app injects a pre-loaded instance
        // from main(); tests can still construct PrivateDeployApp() directly.
        if (appSettings == null)
          ChangeNotifierProvider(create: (_) => AppSettingsProvider())
        else
          ChangeNotifierProvider<AppSettingsProvider>.value(
            value: appSettings,
          ),
        ChangeNotifierProxyProvider2<CloudProvider, ProfileProvider,
            VpnProvider>(
          create: (_) => VpnProvider(),
          update: (ctx, cloudProvider, profileProvider, vpnProvider) {
            vpnProvider?.setFallbackEgressIpResolver(
              cloudProvider.resolveEgressIpForProfileName,
            );
            final appSettings = ctx.read<AppSettingsProvider>();
            // Auto-failover: when the same-node restart budget for an
            // UpstreamDegraded condition is exhausted, cycle through the
            // remaining ready cloud nodes instead of leaving the user
            // stranded on a broken tunnel. The handler is context-free so
            // the watchdog (which runs without a BuildContext) can invoke
            // it directly. Profile state and cloud node discovery come
            // from the providers we just wired in. Routing settings are read
            // at failover time so the new node keeps the user's WG overlay /
            // custom rules instead of connecting a raw, un-normalized config.
            vpnProvider?.setOnDegradedExhausted(
              (triedProfileNames) => autoFailoverToNextCloudNode(
                cloudProvider: cloudProvider,
                profileProvider: profileProvider,
                vpnProvider: vpnProvider,
                triedProfileNames: triedProfileNames,
                routingSettings: appSettings.vpnRoutingSettings,
              ),
            );
            return vpnProvider!;
          },
        ),
        ChangeNotifierProxyProvider3<CloudProvider, VpnProvider,
            ProfileProvider, CdnProvider>(
          // lazy: false so CdnProvider's create+update fire on app boot,
          // not lazily on first widget access. Without this, the Gate ①
          // auto-deploy handler in `update` is never wired until the user
          // navigates to CDN settings — and the whole point of Gate ① is
          // that the user shouldn't need to navigate there.
          lazy: false,
          create: (_) => CdnProvider()..load(),
          update:
              (_, cloudProvider, vpnProvider, profileProvider, cdnProvider) {
            // Wire the CDN provider's deployment lookup into the cloud
            // provider's outbound builder so generated node configs include
            // a CDN-fronted variant whenever a Worker has been deployed.
            cloudProvider.setCdnEndpointResolver((nodeId) {
              final dep = cdnProvider?.deploymentFor(nodeId);
              if (dep == null) return null;
              // Once the user has configured an M1 custom domain for this
              // node, route through it as the PRIMARY hostname regardless
              // of customHostStatus. The status probe runs over the
              // platform DNS resolver, which is exactly what's broken on
              // the carriers where M1 is needed most (CN cellular
              // DNS-poisons both *.workers.dev and the custom hostname).
              // A 'failed' verdict from the probe under those conditions
              // is a false negative.
              //
              // Side-by-side fallback: when a custom domain is bound, we
              // ALSO emit the `*.workers.dev` form as a sibling outbound
              // in the urltest pool. The two paths point at the SAME
              // Worker (same path-secret) and sing-box's connection-time
              // urltest will pick whichever the carrier actually lets
              // through. This replaces the old probe-and-switch logic
              // that left the user stuck on whichever hostname the
              // single client-side probe happened to test first.
              final ch = dep.customHost;
              final isPrimaryCustom = ch != null && ch.isNotEmpty;
              return CdnEndpoint(
                host: isPrimaryCustom ? ch : dep.workerHost,
                pathSecret: dep.pathSecret,
                fallbackHost: isPrimaryCustom ? dep.workerHost : null,
                // 优选IP: only meaningful for the custom-domain path (a pinned
                // IP + workers.dev SNI wouldn't match CF's cert/routing), so
                // pass it through solely when a custom host is the primary.
                preferredEdgeIp:
                    isPrimaryCustom ? cdnProvider?.preferredEdgeIp : null,
              );
            });

            // Gate ① — auto-deploy a Worker for the failing node when the
            // native side reports cellular SYN-block. Conditions
            // intentionally strict so we don't spam CF or surprise users
            // who haven't opted into CDN acceleration:
            //   - CdnProvider verified + has accountId
            //   - workersSubdomain claimed OR a custom domain bound
            //   - Active profile is cloud-managed (we can find the
            //     instance behind it)
            //   - That instance has a vlessRelayPort (Phase-5+ deploy)
            //   - The instance has NO existing deployment yet (otherwise
            //     CDN-fronted variant is already in the pool and urltest
            //     would have picked it — symptom is something else)
            // On success, trigger VPN restart so the rebuilt profile
            // (now carrying the new <label>-CDN outbound) gets picked
            // up. VpnProvider clears _needsCdnGuidance on the next
            // healthy connected transition.
            vpnProvider.setOnAutoCdnDeployRequest((activeProfileName) async {
              // Use developer.log so the diagnostic trace lands in logcat
              // in release builds (AppLogger's default DevelopmentFilter
              // silently drops every record outside debug mode, which is
              // exactly when we need this to be visible during phone e2e).
              void trace(String msg) {
                // ignore: avoid_print
                print('[AutoCDN] $msg');
              }

              trace('handler invoked, profile="$activeProfileName"');
              final cdn = cdnProvider;
              if (cdn == null) {
                trace('skipped: cdnProvider null');
                return false;
              }
              if (!cdn.canAutoDeployForNode()) {
                trace('skipped: canAutoDeployForNode=false '
                    '(status=${cdn.status}, accountId=${cdn.accountId}, '
                    'workersSub=${cdn.workersSubdomain}, '
                    'customDomain=${cdn.customDomain?.hostPattern})');
                // Surface the actionable next step: this user is on
                // cellular, the node is being SYN-blocked, but we can't
                // auto-deploy CDN because they haven't set up CF
                // credentials yet. The guidance banner on the nodes
                // screen also fires here, but a SnackBar is more
                // visible when the user is mid-connect-attempt and
                // staring at the home screen.
                showGlobalSnackBar(
                  '蜂窝网络屏蔽了该节点。请在 CDN 设置中绑定 Cloudflare token 后再试。',
                  duration: const Duration(seconds: 6),
                );
                return false;
              }
              if (activeProfileName == null ||
                  !activeProfileName
                      .startsWith(ProfileProvider.cloudManagedProfilePrefix)) {
                trace('skipped: profile "$activeProfileName" is not '
                    'cloud-managed');
                return false;
              }
              final label = activeProfileName
                  .substring(ProfileProvider.cloudManagedProfilePrefix.length)
                  .trim();
              if (label.isEmpty) {
                trace('skipped: empty label');
                return false;
              }
              CloudInstance? instance;
              for (final candidate in cloudProvider.allInstances) {
                if (candidate.label == label) {
                  instance = candidate;
                  break;
                }
              }
              if (instance == null) {
                trace('skipped: no CloudInstance for label "$label"');
                return false;
              }
              if (!instance.hasIp) {
                trace('skipped: instance ${instance.id} has no IP');
                return false;
              }
              final relayPort = instance.nodeInfo?.vlessRelayPort ?? 0;
              if (relayPort <= 0) {
                trace('skipped: instance ${instance.id} vlessRelayPort='
                    '$relayPort (Phase-5+ deploy required)');
                return false;
              }
              // Deployment may already exist from a previous attempt (auto
              // or manual). DO NOT skip — the saved Hive profile was
              // generated before the deploy succeeded, so its `?k=<secret>`
              // path-secret is stale or empty. urltest then dials the
              // Worker with the wrong secret and Worker returns HTTP 404,
              // killing the probe. Always rebuild the active profile with
              // the current deployment's secret + restart.
              if (cdn.deploymentFor(instance.id) == null) {
                trace('deploying Worker for ${instance.label} '
                    '(${instance.ipv4}:$relayPort)...');
                // First-deploy is the path where the app actually
                // creates a Worker / DNS record / cert on the user's
                // Cloudflare account on their behalf — call it out
                // explicitly. "We're touching your Cloudflare in the
                // background" should never be silent.
                showGlobalSnackBar(
                  '检测到蜂窝运营商屏蔽该节点，正在你的 Cloudflare 账号下'
                  '为 ${instance.label} 部署加速 Worker…',
                  duration: const Duration(seconds: 4),
                );
                final deployed = await cdn.deployWorkerForNode(
                  nodeId: instance.id,
                  nodeLabel: instance.label,
                  backendHost: instance.ipv4!,
                  backendPort: relayPort,
                  // Provenance: Gate ① path. Surfaced on the CDN
                  // settings node row so users can tell auto-deployed
                  // Workers apart from ones they explicitly created.
                  deployedBy: 'auto',
                );
                if (!deployed) {
                  trace('deployWorkerForNode returned false: '
                      '${cdn.lastError}');
                  showGlobalSnackBar(
                    'CDN 加速部署失败：${cdn.lastError ?? "未知错误"}。'
                    '可前往 CDN 设置查看详情。',
                    duration: const Duration(seconds: 6),
                  );
                  return false;
                }
                trace('deploy succeeded for ${instance.label}');
              } else {
                trace('deployment already exists for ${instance.id}; '
                    'rebuilding active profile to pick up current secret');
                // No CF API hit on this branch — just rebuilding the
                // local profile to pick up the existing deployment's
                // secret. Still announce it so the user knows the app
                // is doing recovery work and isn't just hung.
                showGlobalSnackBar(
                  '正在切换到 CDN 加速线路…',
                  duration: const Duration(seconds: 3),
                );
              }

              // Rebuild the active profile using buildCloudNodeConfig which
              // now sees the deployment via cdnEndpointResolver, so the new
              // config carries the correct `?k=<secret>` and the
              // <label>-CDN outbound is in the urltest pool front (Gate ②).
              final rebuiltConfig = cloudProvider.generateNodeConfig(instance);
              if (rebuiltConfig == null) {
                trace('generateNodeConfig returned null for '
                    '${instance.label}; abandoning');
                return false;
              }
              final existing = profileProvider.profiles
                  .where((p) => p.name == activeProfileName)
                  .firstOrNull;
              if (existing != null) {
                final saved = await profileProvider.saveProfileContent(
                  existing.id,
                  rebuiltConfig,
                );
                if (!saved) {
                  trace('saveProfileContent failed: '
                      '${profileProvider.error}');
                  return false;
                }
                final activated =
                    await profileProvider.activateProfile(existing.id);
                if (!activated) {
                  trace('activateProfile failed: ${profileProvider.error}');
                  return false;
                }
              }

              // Diagnostic: prove the rebuilt JSON actually carries the
              // CDN outbound + DNS carve-out. If either is missing the
              // resolver pipeline broke and we'd silently dial bare IPs.
              final hasCdnTag = rebuiltConfig.contains('-CDN');
              final hasDnsCarveout = rebuiltConfig.contains('relay-');
              final existingDep = cdn.deploymentFor(instance.id);
              final secret = existingDep?.pathSecret ?? '';
              final secretFingerprint = secret.isEmpty
                  ? '<empty>'
                  : '${secret.substring(0, 6)}... (len=${secret.length})';
              trace('rebuilt config: hasCdnTag=$hasCdnTag '
                  'hasDnsCarveout=$hasDnsCarveout '
                  'length=${rebuiltConfig.length} '
                  'depSecret=$secretFingerprint '
                  'customHost=${existingDep?.customHost} '
                  'workerHost=${existingDep?.workerHost}');
              // Probe Worker directly with the stored secret BEFORE
              // re-trying VPN. If this returns false, the Worker on CF
              // has a different secret than our local record, so the
              // saved pathSecret is stale and re-deployment is needed.
              final reach = await cdn.debugTestCdnWorkerReachable(instance.id);
              trace('worker reachable with stored secret = $reach');
              trace('restarting VPN with rebuilt profile (CDN-front first)');
              showGlobalSnackBar(
                '已启用 CDN 加速，正在重新连接…',
                duration: const Duration(seconds: 3),
              );
              await vpnProvider.connect(
                configJson: rebuiltConfig,
                profileName: activeProfileName,
              );
              return true;
            });
            return cdnProvider!;
          },
        ),
      ],
      child: ScreenUtilInit(
        designSize: const Size(375, 812),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, child) {
          return MaterialApp(
            title: 'PrivateDeploy',
            debugShowCheckedModeBanner: false,
            // App-wide messenger so the Gate ① auto-CDN handler — which
            // runs without a BuildContext — can surface SnackBars to
            // whoever's looking at the app right now. Without this the
            // auto-deploy path could only print to logcat, leaving the
            // user staring at a slowly-reconnecting VPN with no idea
            // their Cloudflare account was just touched on their behalf.
            scaffoldMessengerKey: globalScaffoldMessengerKey,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              primarySwatch: Colors.blue,
              useMaterial3: true,
            ),
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
