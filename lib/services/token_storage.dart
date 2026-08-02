import 'package:shared_preferences/shared_preferences.dart';

class TokenStorage {
  static const _accessTokenKey = 'restaurant_ops_access_token';
  static const _refreshTokenKey = 'restaurant_ops_refresh_token';

  Future<String?> getAccessToken() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_accessTokenKey);
  }

  Future<String?> getRefreshToken() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_refreshTokenKey);
  }

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(_accessTokenKey, accessToken),
      preferences.setString(_refreshTokenKey, refreshToken),
    ]);
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.remove(_accessTokenKey),
      preferences.remove(_refreshTokenKey),
    ]);
  }
}
