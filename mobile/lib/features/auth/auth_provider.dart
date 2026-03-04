import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/storage_service.dart';

class AuthProvider with ChangeNotifier {
  static const String _usernameStorageKey = 'auth_username';

  bool _isAuthenticated = false;
  String? _token;
  String? _username;
  bool _isLoading = false;
  String? _error;

  bool get isAuthenticated => _isAuthenticated;
  String? get token => _token;
  String? get username => _username;
  bool get isLoading => _isLoading;
  String? get error => _error;

  AuthProvider() {
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    _token = StorageService.getToken();
    final storedUsername = StorageService.getString(_usernameStorageKey);
    _username = (storedUsername == null || storedUsername.isEmpty) ? null : storedUsername;
    _isAuthenticated = _token != null;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final dio = DioClient.createDio();
      final apiClient = ApiClient(dio);
      
      final response = await apiClient.login({
        'username': username,
        'password': password,
      });

      if (response['success'] == true) {
        _token = response['data']['token'];
        _username = username;
        await StorageService.saveToken(_token!);
        await StorageService.saveString(_usernameStorageKey, username);
        _isAuthenticated = true;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = response['error']?['message'] ?? 'Login failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await StorageService.clearToken();
    await StorageService.remove(_usernameStorageKey);
    _token = null;
    _username = null;
    _isAuthenticated = false;
    notifyListeners();
  }
}
