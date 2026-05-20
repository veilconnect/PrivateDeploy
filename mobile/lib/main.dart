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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();

  // Initialize Storage
  await StorageService.init();

  // Install bundled routing rule sets before the app starts so the first VPN
  // connection can immediately apply CN split-routing rules.
  await BundledRuleSetRegistry.ensureInstalled();

  runApp(const PrivateDeployApp());
}

class PrivateDeployApp extends StatelessWidget {
  const PrivateDeployApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProfileProvider()),
        ChangeNotifierProvider(create: (_) => CloudProvider()),
        ChangeNotifierProxyProvider2<CloudProvider, ProfileProvider,
            VpnProvider>(
          create: (_) => VpnProvider(),
          update: (_, cloudProvider, profileProvider, vpnProvider) {
            vpnProvider?.setFallbackEgressIpResolver(
              cloudProvider.resolveEgressIpForProfileName,
            );
            // Auto-failover: when the same-node restart budget for an
            // UpstreamDegraded condition is exhausted, cycle through the
            // remaining ready cloud nodes instead of leaving the user
            // stranded on a broken tunnel. The handler is context-free so
            // the watchdog (which runs without a BuildContext) can invoke
            // it directly. Profile state and cloud node discovery come
            // from the providers we just wired in.
            vpnProvider?.setOnDegradedExhausted(
              (triedProfileNames) => autoFailoverToNextCloudNode(
                cloudProvider: cloudProvider,
                profileProvider: profileProvider,
                vpnProvider: vpnProvider,
                triedProfileNames: triedProfileNames,
              ),
            );
            return vpnProvider!;
          },
        ),
        ChangeNotifierProvider(create: (_) => AppSettingsProvider()),
        ChangeNotifierProxyProvider3<CloudProvider, VpnProvider, ProfileProvider, CdnProvider>(
          // lazy: false so CdnProvider's create+update fire on app boot,
          // not lazily on first widget access. Without this, the Gate ①
          // auto-deploy handler in `update` is never wired until the user
          // navigates to CDN settings — and the whole point of Gate ① is
          // that the user shouldn't need to navigate there.
          lazy: false,
          create: (_) => CdnProvider()..load(),
          update: (_, cloudProvider, vpnProvider, profileProvider, cdnProvider) {
            // Wire the CDN provider's deployment lookup into the cloud
            // provider's outbound builder so generated node configs include
            // a CDN-fronted variant whenever a Worker has been deployed.
            cloudProvider.setCdnEndpointResolver((nodeId) {
              final dep = cdnProvider?.deploymentFor(nodeId);
              if (dep == null) return null;
              // Once the user has configured an M1 custom domain for this
              // node, route through it regardless of customHostStatus.
              // The status probe runs over the platform DNS resolver,
              // which is exactly what's broken on the carriers where M1
              // is needed most (regional mobile network DNS-poisons both *.workers.dev
              // and the custom hostname). A 'failed' verdict from the
              // probe under those conditions is a false negative, and
              // falling back to workers.dev pushes traffic onto a more
              // altered path. sing-box's internal DoH resolves the
              // custom host correctly, so let it try. The 'pending'
              // window (~60s while CF provisions the cert) is still a
              // real failure mode — we surface it as a UI banner instead
              // of silently rerouting.
              final ch = dep.customHost;
              final host =
                  (ch != null && ch.isNotEmpty) ? ch : dep.workerHost;
              return CdnEndpoint(
                host: host,
                pathSecret: dep.pathSecret,
              );
            });

            // Gate ① — auto-deploy a Worker for the failing node when the
            // native side reports cellular connectivity failure. Conditions
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
                final deployed = await cdn.deployWorkerForNode(
                  nodeId: instance.id,
                  nodeLabel: instance.label,
                  backendHost: instance.ipv4!,
                  backendPort: relayPort,
                );
                if (!deployed) {
                  trace('deployWorkerForNode returned false: '
                      '${cdn.lastError}');
                  return false;
                }
                trace('deploy succeeded for ${instance.label}');
              } else {
                trace('deployment already exists for ${instance.id}; '
                    'rebuilding active profile to pick up current secret');
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
              trace('rebuilt config: hasCdnTag=$hasCdnTag '
                  'hasDnsCarveout=$hasDnsCarveout '
                  'length=${rebuiltConfig.length}');
              trace('restarting VPN with rebuilt profile (CDN-front first)');
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
