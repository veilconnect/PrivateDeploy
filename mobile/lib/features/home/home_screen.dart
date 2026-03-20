import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../vpn/vpn_screen.dart';
import '../vpn/vpn_provider.dart';
import '../profiles/profile_screen.dart';
import '../cloud/cloud_screen.dart';
import 'package:provider/provider.dart';

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
            ],
          ),
        ),
      ],
    );
  }
}
