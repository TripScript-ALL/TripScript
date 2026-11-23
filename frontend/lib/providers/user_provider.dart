import 'package:flutter/widgets.dart';

import '../models/user.dart';
import '../services/api_service.dart';

/// `--dart-define=SKIP_LOGIN=true` 용 로컬 더미 사용자
User kLocalDevUser() => const User(
      id: '00000000-0000-4000-8000-000000000001',
      name: '로컬개발',
      phoneNumber: '01000000000',
    );

class UserProvider with ChangeNotifier {
  UserProvider(this._api);

  final ApiService _api;

  User? _currentUser;
  User? get currentUser => _currentUser;

  /// `SKIP_LOGIN` 등에서만 사용. 네트워크 없이 세션만 맞춥니다.
  void applyLocalDevSession(User user) {
    _currentUser = user;
    _error = null;
    notifyListeners();
  }

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  /// 저장된 앱 Bearer 토큰으로 세션 복구 (`GET /me`).
  Future<bool> restoreFromApiToken() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _api.getCurrentUser();
      _currentUser = user;
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 카카오 액세스 토큰으로 서버 로그인 후 [currentUser] 설정.
  Future<bool> loginWithKakaoAccessToken(String kakaoAccessToken) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _api.loginWithKakaoAccessToken(kakaoAccessToken);
      _currentUser = user;
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 이름+전화번호로 사용자 로드
  Future<bool> loadUserByNameAndPhone(String name, String phoneNumber) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _api.getUserByNameAndPhone(name, phoneNumber);
      _currentUser = user;
      return user != null;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 사용자 등록 (이름, 전화번호)
  Future<void> register({
    required String name,
    required String phoneNumber,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _api.registerUser(
        name: name,
        phoneNumber: phoneNumber,
      );
      _currentUser = user;
    } on ApiException catch (e) {
      _error = e.message;
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 사용자 정보 수정
  Future<void> updateProfile({
    required String name,
    required String phoneNumber,
    String? nickname,
    String? settlementBankName,
    String? settlementAccountNumber,
    String? settlementAccountHolder,
  }) async {
    if (_currentUser == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _api.updateUser(
        _currentUser!.id,
        name: name,
        phoneNumber: phoneNumber,
        nickname: nickname,
        settlementBankName: settlementBankName,
        settlementAccountNumber: settlementAccountNumber,
        settlementAccountHolder: settlementAccountHolder,
      );
      _currentUser = user;
    } on ApiException catch (e) {
      _error = e.message;
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteAccount() async {
    final user = _currentUser;
    if (user == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _api.deleteUser(user.id);
      _currentUser = null;
      _api.clearAuthToken();
    } on ApiException catch (e) {
      _error = e.message;
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// 로컬 세션만 종료 (저장소 정리는 호출 측에서 StorageService 등으로 처리)
  void logout() {
    _currentUser = null;
    _error = null;
    _api.clearAuthToken();
    notifyListeners();
  }
}
