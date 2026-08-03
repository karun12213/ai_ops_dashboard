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
      AuthService(
        apiClient,
        tokenStorage,
      ).login(email: 'operator@example.com', password: 'example-password'),
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
      AuthService(
        apiClient,
        tokenStorage,
      ).login(email: 'operator@example.com', password: 'example-password'),
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

  test(
    'refreshes an expired access token and retries the request once',
    () async {
      final tokenStorage = _MemoryTokenStorage()
        .._accessToken = 'expired-access-token'
        .._refreshToken = 'original-refresh-token';
      var profileRequests = 0;
      var refreshRequests = 0;
      final apiClient = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshRequests += 1;
            expect(request.headers['authorization'], isNull);
            expect(
              jsonDecode(request.body),
              equals({'refresh_token': 'original-refresh-token'}),
            );
            return http.Response(
              jsonEncode({
                'access_token': 'rotated-access-token',
                'refresh_token': 'rotated-refresh-token',
                'token_type': 'bearer',
                'expires_in': 1800,
              }),
              200,
            );
          }

          profileRequests += 1;
          if (request.headers['authorization'] ==
              'Bearer expired-access-token') {
            return http.Response(jsonEncode({'detail': 'expired'}), 401);
          }
          expect(
            request.headers['authorization'],
            'Bearer rotated-access-token',
          );
          return http.Response(
            jsonEncode({
              'id': 'user-id',
              'email': 'operator@example.com',
              'full_name': 'Test Operator',
              'is_active': true,
              'is_superuser': false,
            }),
            200,
          );
        }),
        tokenStorage: tokenStorage,
      );

      final user = await AuthService(apiClient, tokenStorage).currentUser();

      expect(user.email, 'operator@example.com');
      expect(profileRequests, 2);
      expect(refreshRequests, 1);
      expect(await tokenStorage.getAccessToken(), 'rotated-access-token');
      expect(await tokenStorage.getRefreshToken(), 'rotated-refresh-token');
    },
  );

  test(
    'shares one refresh across simultaneous authenticated requests',
    () async {
      final tokenStorage = _MemoryTokenStorage()
        .._accessToken = 'expired-access-token'
        .._refreshToken = 'original-refresh-token';
      var refreshRequests = 0;
      var protectedRequests = 0;
      final apiClient = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshRequests += 1;
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return http.Response(
              jsonEncode({
                'access_token': 'rotated-access-token',
                'refresh_token': 'rotated-refresh-token',
                'expires_in': 1800,
              }),
              200,
            );
          }

          protectedRequests += 1;
          if (request.headers['authorization'] ==
              'Bearer expired-access-token') {
            return http.Response(jsonEncode({'detail': 'expired'}), 401);
          }
          expect(
            request.headers['authorization'],
            'Bearer rotated-access-token',
          );
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
        tokenStorage: tokenStorage,
      );

      final results = await Future.wait([
        apiClient.get('/protected'),
        apiClient.get('/protected'),
      ]);

      expect(results, everyElement(equals({'ok': true})));
      expect(protectedRequests, 4);
      expect(refreshRequests, 1);
    },
  );

  test('restores a session when only a refresh token is available', () async {
    final tokenStorage = _MemoryTokenStorage()
      .._refreshToken = 'saved-refresh-token';
    var refreshRequests = 0;
    final apiClient = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshRequests += 1;
          return http.Response(
            jsonEncode({
              'access_token': 'restored-access-token',
              'refresh_token': 'restored-refresh-token',
              'expires_in': 1800,
            }),
            200,
          );
        }
        expect(
          request.headers['authorization'],
          'Bearer restored-access-token',
        );
        return http.Response(
          jsonEncode({
            'id': 'user-id',
            'email': 'operator@example.com',
            'full_name': 'Test Operator',
            'is_active': true,
            'is_superuser': false,
          }),
          200,
        );
      }),
      tokenStorage: tokenStorage,
    );

    final user = await AuthService(apiClient, tokenStorage).restoreSession();

    expect(user?.email, 'operator@example.com');
    expect(refreshRequests, 1);
    expect(await tokenStorage.getAccessToken(), 'restored-access-token');
  });

  test('clears the session only when refresh fails', () async {
    final tokenStorage = _MemoryTokenStorage()
      .._accessToken = 'expired-access-token'
      .._refreshToken = 'rejected-refresh-token';
    var protectedRequests = 0;
    var refreshRequests = 0;
    final apiClient = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshRequests += 1;
          return http.Response(jsonEncode({'detail': 'invalid'}), 401);
        }
        protectedRequests += 1;
        return http.Response(jsonEncode({'detail': 'expired'}), 401);
      }),
      tokenStorage: tokenStorage,
    );

    await expectLater(
      apiClient.get('/protected'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );

    expect(protectedRequests, 1);
    expect(refreshRequests, 1);
    expect(await tokenStorage.getAccessToken(), isNull);
    expect(await tokenStorage.getRefreshToken(), isNull);
  });

  test(
    'does not discard tokens for a non-authentication server error',
    () async {
      final tokenStorage = _MemoryTokenStorage()
        .._accessToken = 'valid-access-token'
        .._refreshToken = 'valid-refresh-token';
      final apiClient = ApiClient(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'detail': 'unavailable'}), 503),
        ),
        tokenStorage: tokenStorage,
      );

      await expectLater(
        apiClient.get('/protected'),
        throwsA(isA<ApiException>()),
      );

      expect(await tokenStorage.getAccessToken(), 'valid-access-token');
      expect(await tokenStorage.getRefreshToken(), 'valid-refresh-token');
    },
  );
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
