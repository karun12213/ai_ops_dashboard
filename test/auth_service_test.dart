import 'dart:convert';

import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/auth_service.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:ai_ops_dashboard/utils/app_constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('uses the local API URL and exact backend login contract', () async {
    expect(AppConstants.apiBaseUrl, 'http://localhost:8000/api/v1');

    final tokenStorage = _MemoryTokenStorage();
    var requestCount = 0;
    final httpClient = MockClient((request) async {
      requestCount += 1;
      if (requestCount == 1) {
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse('http://localhost:8000/api/v1/auth/login'),
        );
        expect(request.headers['authorization'], isNull);
        expect(
          jsonDecode(request.body),
          equals({
            'email': 'operator@example.com',
            'password': 'example-password',
          }),
        );
        return http.Response(
          jsonEncode({
            'access_token': 'test-access-token',
            'refresh_token': 'test-refresh-token',
            'token_type': 'bearer',
            'expires_in': 1800,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      expect(request.method, 'GET');
      expect(request.url, Uri.parse('http://localhost:8000/api/v1/auth/me'));
      expect(request.headers['authorization'], 'Bearer test-access-token');
      return http.Response(
        jsonEncode({
          'id': 'user-id',
          'email': 'operator@example.com',
          'full_name': 'Test Operator',
          'is_active': true,
          'is_superuser': false,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final apiClient = ApiClient(client: httpClient, tokenStorage: tokenStorage);

    final user = await AuthService(
      apiClient,
      tokenStorage,
    ).login(email: ' Operator@Example.com ', password: 'example-password');

    expect(user.email, 'operator@example.com');
    expect(requestCount, 2);
  });

  test('preserves HTTP status when an error body is not JSON', () async {
    final apiClient = ApiClient(
      client: MockClient((_) async => http.Response('server error', 500)),
      tokenStorage: _MemoryTokenStorage(),
    );

    await expectLater(
      apiClient.post('/auth/login', authenticated: false),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          500,
        ),
      ),
    );
  });

  test('maps only a login endpoint 401 to invalid credentials', () async {
    final tokenStorage = _MemoryTokenStorage();
    final apiClient = ApiClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'Incorrect email or password'}),
          401,
          headers: {'content-type': 'application/json'},
        ),
      ),
      tokenStorage: tokenStorage,
    );

    await expectLater(
      AuthService(apiClient, tokenStorage).login(
        email: 'operator@example.com',
        password: 'example-password',
      ),
      throwsA(isA<InvalidCredentialsException>()),
    );
  });

  test('clears tokens when the issued session cannot load the user', () async {
    final tokenStorage = _MemoryTokenStorage();
    var requestCount = 0;
    final apiClient = ApiClient(
      client: MockClient((_) async {
        requestCount += 1;
        if (requestCount == 1) {
          return http.Response(
            jsonEncode({
              'access_token': 'test-access-token',
              'refresh_token': 'test-refresh-token',
              'token_type': 'bearer',
              'expires_in': 1800,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'detail': 'Could not validate credentials'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
      tokenStorage: tokenStorage,
    );

    await expectLater(
      AuthService(apiClient, tokenStorage).login(
        email: 'operator@example.com',
        password: 'example-password',
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
    expect(await tokenStorage.getAccessToken(), isNull);
    expect(await tokenStorage.getRefreshToken(), isNull);
  });
}

class _MemoryTokenStorage extends TokenStorage {
  String? _accessToken;
  String? _refreshToken;

  @override
  Future<String?> getAccessToken() async => _accessToken;

  @override
  Future<String?> getRefreshToken() async => _refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
  }

  @override
  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
  }
}
