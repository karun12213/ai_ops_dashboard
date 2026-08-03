import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_constants.dart';
import 'token_storage.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client, TokenStorage? tokenStorage})
    : _client = client ?? http.Client(),
      _tokenStorage = tokenStorage ?? TokenStorage();

  final http.Client _client;
  final TokenStorage _tokenStorage;
  Future<bool>? _refreshInFlight;

  static const _requestTimeout = Duration(seconds: 15);

  Uri _uri(String path) => AppConstants.apiUri(path);

  Future<Map<String, dynamic>> get(
    String path, {
    bool authenticated = true,
  }) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        send: (headers) => _client.get(_uri(path), headers: headers),
      );
      return _decode(response);
    } on TimeoutException {
      throw const ApiException('The API did not respond in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        send: (headers) => _client.post(
          _uri(path),
          headers: headers,
          body: jsonEncode(body ?? const <String, dynamic>{}),
        ),
      );
      return _decode(response);
    } on TimeoutException {
      throw const ApiException('The API did not respond in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<http.Response> _sendWithAuthRetry({
    required bool authenticated,
    required Future<http.Response> Function(Map<String, String> headers) send,
  }) async {
    final initial = await _headers(authenticated);
    final response = await send(initial.headers).timeout(_requestTimeout);
    if (!authenticated || response.statusCode != 401) return response;

    // Another request may already have completed a refresh after this request
    // left with the old access token. Reuse that newer token before starting a
    // second rotation.
    final currentAccessToken = await _tokenStorage.getAccessToken();
    if (initial.accessToken != null &&
        currentAccessToken != null &&
        currentAccessToken != initial.accessToken) {
      final retryHeaders = await _headers(true);
      return send(retryHeaders.headers).timeout(_requestTimeout);
    }

    if (!await refreshAccessToken()) return response;
    final retryHeaders = await _headers(true);
    return send(retryHeaders.headers).timeout(_requestTimeout);
  }

  /// Rotates the saved refresh token, coalescing simultaneous refreshes.
  Future<bool> refreshAccessToken() {
    final activeRefresh = _refreshInFlight;
    if (activeRefresh != null) return activeRefresh;

    final refresh = _performRefresh();
    _refreshInFlight = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
      }),
    );
    return refresh;
  }

  Future<bool> _performRefresh() async {
    final refreshToken = await _tokenStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _tokenStorage.clear();
      return false;
    }

    try {
      final response = await _client
          .post(
            _uri('/auth/refresh'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(_requestTimeout);
      final payload = _decode(response);
      final accessToken = payload['access_token'];
      final rotatedRefreshToken = payload['refresh_token'];
      if (accessToken is! String ||
          accessToken.isEmpty ||
          rotatedRefreshToken is! String ||
          rotatedRefreshToken.isEmpty) {
        throw ApiException(
          'The API returned an invalid authentication response.',
          statusCode: response.statusCode,
        );
      }
      await _tokenStorage.saveTokens(
        accessToken: accessToken,
        refreshToken: rotatedRefreshToken,
      );
      return true;
    } catch (_) {
      await _tokenStorage.clear();
      return false;
    }
  }

  Future<({Map<String, String> headers, String? accessToken})> _headers(
    bool authenticated,
  ) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    String? accessToken;
    if (authenticated) {
      accessToken = await _tokenStorage.getAccessToken();
      if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    }
    return (headers: headers, accessToken: accessToken);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> payload = const {};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } on FormatException {
        throw ApiException(
          'The API returned an invalid response.',
          statusCode: response.statusCode,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = payload['detail'];
      final message = detail is String
          ? detail
          : 'The request could not be completed.';
      throw ApiException(message, statusCode: response.statusCode);
    }
    return payload;
  }
}
