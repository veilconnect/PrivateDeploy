import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../core/storage/storage_service.dart';
import 'auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _usernameStorageKey = 'auth_username';
  static const String _debugPassword =
      String.fromEnvironment('PRIVATEDEPLOY_DEBUG_PASSWORD');

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _debugAutoLoginTriggered = false;

  @override
  void initState() {
    super.initState();
    final storedUsername = StorageService.getString(_usernameStorageKey);
    if (storedUsername != null && storedUsername.isNotEmpty) {
      _usernameController.text = storedUsername;
    }
    if (_shouldUseDebugPassword()) {
      _passwordController.text = _debugPassword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _debugAutoLoginTriggered) {
          return;
        }
        _debugAutoLoginTriggered = true;
        _handleLogin();
      });
    }
  }

  bool _shouldUseDebugPassword() {
    if (!kDebugMode || _debugPassword.isEmpty) {
      return false;
    }
    if (_usernameController.text.trim().isEmpty) {
      return false;
    }
    final baseUrl = StorageService.getApiBaseUrl();
    return baseUrl.contains('127.0.0.1') || baseUrl.contains('10.0.2.2');
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_formKey.currentState!.validate()) {
      final auth = context.read<AuthProvider>();
      final success = await auth.login(
        _usernameController.text,
        _passwordController.text,
      );

      if (success && mounted) {
        FocusScope.of(context).unfocus();
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
        }
        return;
      }

      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(auth.error ?? 'Login failed'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24.w),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'PrivateDeploy',
                  style: TextStyle(
                    fontSize: 32.sp,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 48.h),
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter username';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 16.h),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter password';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 24.h),
                Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    if (auth.isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return ElevatedButton(
                      onPressed: _handleLogin,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 16.h),
                      ),
                      child: Text(
                        'Login',
                        style: TextStyle(fontSize: 16.sp),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
