import 'package:flutter/material.dart';

import '../cloud/cloud_screen.dart';
import '../profiles/profile_screen.dart';
import '../settings/settings_screen.dart';
import '../vpn/vpn_screen.dart';

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
        return const SettingsScreen();
      default:
        return const VpnScreen();
    }
  }
}
