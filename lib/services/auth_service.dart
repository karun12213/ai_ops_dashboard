import '../models/auth_tokens.dart';
import '../models/user.dart';
import 'api_client.dart';
import 'token_storage.dart';

class InvalidCredentialsException implements Exception {
  const InvalidCredentialsException();
}

class AuthService {
  AuthService(this._apiClient, this._tokenStorage);

  final ApiClient _apiClient;
  final TokenStorage _tokenStorage;

  Future<User> login({required String email, required String password}) async {
    late final Map<String, dynamic> payload;
    try {
      payload = await _apiClient.post(
        '/auth/login',
        body: {'email': email.trim().toLowerCase(), 'password': password},
        authenticated: false,
      );
    } on ApiException catch (error) {
      // A 401 means invalid credentials only when it came from the login
      // endpoint itself. A later /auth/me 401 means the issued session could
      // not be validated and must not be presented as a password failure.
      if (error.statusCode == 401) {
        throw const InvalidCredentialsException();
      }
      rethrow;
    }

    try {
      final tokens = AuthTokens.fromJson(payload);
      await _tokenStorage.saveTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      return await currentUser();
    } catch (_) {
      // Never retain a partial session if token parsing, persistence, or the
      // authenticated profile request fails.
      await _tokenStorage.clear();
      rethrow;
    }
  }

  Future<User> currentUser() async {
    final payload = await _apiClient.get('/auth/me');
    return User.fromJson(payload);
  }

  Future<User?> restoreSession() async {
    final accessToken = await _tokenStorage.getAccessToken();
    final refreshToken = await _tokenStorage.getRefreshToken();
    if (accessToken == null && refreshToken == null) return null;
    if (accessToken == null && !await _apiClient.refreshAccessToken()) {
      return null;
    }
    try {
      // ApiClient rotates the refresh token and retries once if this access
      // token is expired. Non-authentication failures preserve the saved
      // session so a temporary outage does not destroy valid credentials.
      return await currentUser();
    } on ApiException catch (error) {
      if (error.statusCode == 401) await _tokenStorage.clear();
      return null;
    } catch (_) {
      // A temporarily unavailable API must not leave the application stuck on
      // its loading screen when a token was saved by an earlier session.
      return null;
    }
  }

  Future<void> logout() async {
    final refreshToken = await _tokenStorage.getRefreshToken();
    if (refreshToken != null) {
      try {
        await _apiClient.post(
          '/auth/logout',
          body: {'refresh_token': refreshToken},
        );
      } catch (_) {
        // Best-effort server-side revocation; the local session must still
        // end even if the network call fails.
      }
    }
    await _tokenStorage.clear();
  }
}
