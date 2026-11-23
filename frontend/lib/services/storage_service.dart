import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const _nameKey = 'user_name';
  static const _phoneKey = 'user_phone';
  static const _userIdKey = 'user_id';
  static const _apiAccessTokenKey = 'api_access_token';

  Future<String?> getApiAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiAccessTokenKey);
  }

  Future<String?> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey);
  }

  Future<String?> getUserPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_phoneKey);
  }

  Future<String?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userIdKey);
  }

  Future<void> saveApiAccessToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove(_apiAccessTokenKey);
    } else {
      await prefs.setString(_apiAccessTokenKey, token);
    }
  }

  Future<void> saveUserCredentials({
    required String name,
    required String phone,
    required String userId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
    await prefs.setString(_phoneKey, phone);
    await prefs.setString(_userIdKey, userId);
  }

  Future<void> clearUserCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    await prefs.remove(_phoneKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_apiAccessTokenKey);
  }

  Future<bool> hasUserCredentials() async {
    final name = await getUserName();
    final phone = await getUserPhone();
    return name != null && name.isNotEmpty && phone != null && phone.isNotEmpty;
  }

  /// JWT만 있어도 true(카카오 등 전화 없이 저장된 경우 포함).
  /// 이름+전화만 있고 토큰이 없을 때는 게스트 복구용으로 true.
  Future<bool> hasStoredSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_apiAccessTokenKey);
    if (token != null && token.isNotEmpty) {
      return true;
    }
    final name = prefs.getString(_nameKey);
    final phone = prefs.getString(_phoneKey);
    return name != null && name.isNotEmpty && phone != null && phone.isNotEmpty;
  }
}
