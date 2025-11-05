import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/storage_service.dart';

class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  String? _token;
  bool _isLoading = false;
  String? _error;

  bool get isAuthenticated => _isAuthenticated;
  String? get token => _token;
  bool get isLoading => _isLoading;
  String? get error => _error;

  AuthProvider() {
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    _token = StorageService.getToken();
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
        await StorageService.saveToken(_token!);
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
    _token = null;
    _isAuthenticated = false;
    notifyListeners();
  }
}
