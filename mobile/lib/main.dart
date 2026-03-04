import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/network/api_client.dart';
import 'core/storage/storage_service.dart';
import 'features/auth/auth_provider.dart';
import 'features/home/home_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/cloud/cloud_provider.dart';
import 'features/profiles/profile_provider.dart';
import 'features/vpn/vpn_provider.dart';
import 'features/dashboard/dashboard_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive
  await Hive.initFlutter();
  
  // Initialize Storage
  await StorageService.init();
  
  runApp(const PrivateDeployApp());
}

class PrivateDeployApp extends StatelessWidget {
  const PrivateDeployApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dio = DioClient.createDio();
    final apiClient = ApiClient(dio);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => CloudProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => ProfileProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => VpnProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => DashboardProvider(apiClient)),
      ],
      child: ScreenUtilInit(
        designSize: const Size(375, 812),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, child) {
          return MaterialApp(
            title: 'PrivateDeploy',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              primarySwatch: Colors.blue,
              useMaterial3: true,
            ),
            home: Consumer<AuthProvider>(
              builder: (context, auth, _) {
                return auth.isAuthenticated
                    ? const HomeScreen()
                    : const LoginScreen();
              },
            ),
          );
        },
      ),
    );
  }
}
