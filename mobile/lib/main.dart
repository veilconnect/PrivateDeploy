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
import 'features/cloud/cloud_provider.dart';

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
        ChangeNotifierProxyProvider<CloudProvider, VpnProvider>(
          create: (_) => VpnProvider(),
          update: (_, cloudProvider, vpnProvider) {
            vpnProvider?.setFallbackEgressIpResolver(
              cloudProvider.resolveEgressIpForProfileName,
            );
            return vpnProvider!;
          },
        ),
        ChangeNotifierProvider(create: (_) => AppSettingsProvider()),
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
