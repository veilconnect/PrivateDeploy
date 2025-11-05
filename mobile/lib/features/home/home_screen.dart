import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../auth/auth_provider.dart';
import '../vpn/vpn_screen.dart';
import '../vpn/vpn_provider.dart';
import '../cloud/cloud_screen.dart';
import '../profiles/profile_screen.dart';
import '../dashboard/dashboard_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.vpn_lock),
            label: 'VPN',
          ),
          NavigationDestination(
            icon: Icon(Icons.description),
            label: 'Profiles',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud),
            label: 'Cloud',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return const VpnScreen();
      case 1:
        return const ProfileScreen();
      case 2:
        return const CloudScreen();
      case 3:
        return _buildSettingsTab();
      default:
        return const VpnScreen();
    }
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: EdgeInsets.all(16.w),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Account'),
                subtitle: Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    return Text(auth.username ?? 'Not logged in');
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.vpn_key),
                title: const Text('VPN Status'),
                subtitle: Consumer<VpnProvider>(
                  builder: (context, vpn, _) {
                    return Text(vpn.isConnected ? 'Connected' : 'Disconnected');
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.dashboard),
                title: const Text('Dashboard'),
                subtitle: const Text('View system statistics and charts'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const DashboardScreen(),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info),
                title: const Text('About'),
                subtitle: const Text('PrivateDeploy Mobile v1.0.0'),
                onTap: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'PrivateDeploy',
                    applicationVersion: '1.0.0',
                    applicationLegalese: '© 2024 PrivateDeploy',
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text(
                  'Logout',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Logout'),
                      content: const Text('Are you sure you want to logout?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            Navigator.pop(context);
                            context.read<AuthProvider>().logout();
                          },
                          child: const Text('Logout'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
