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
        ChangeNotifierProxyProvider2<CloudProvider, VpnProvider, CdnProvider>(
          create: (_) => CdnProvider()..load(),
          update: (_, cloudProvider, vpnProvider, cdnProvider) {
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
              final cdn = cdnProvider;
              if (cdn == null) return false;
              if (!cdn.canAutoDeployForNode()) return false;
              if (activeProfileName == null ||
                  !activeProfileName
                      .startsWith(ProfileProvider.cloudManagedProfilePrefix)) {
                return false;
              }
              final label = activeProfileName
                  .substring(ProfileProvider.cloudManagedProfilePrefix.length)
                  .trim();
              if (label.isEmpty) return false;
              CloudInstance? instance;
              for (final candidate in cloudProvider.allInstances) {
                if (candidate.label == label) {
                  instance = candidate;
                  break;
                }
              }
              if (instance == null) return false;
              if (!instance.hasIp) return false;
              final relayPort = instance.nodeInfo?.vlessRelayPort ?? 0;
              if (relayPort <= 0) return false;
              if (cdn.deploymentFor(instance.id) != null) return false;

              final deployed = await cdn.deployWorkerForNode(
                nodeId: instance.id,
                nodeLabel: instance.label,
                backendHost: instance.ipv4!,
                backendPort: relayPort,
              );
              if (!deployed) return false;

              // Profile is rebuilt by VpnProvider.restart() because
              // cdnEndpointResolver now returns a non-null endpoint for
              // this instance. urltest pool will lead with <label>-CDN
              // (Gate ②), so the next probe sweep should land Healthy.
              await vpnProvider.restart();
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
