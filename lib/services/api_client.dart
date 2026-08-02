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

  Uri _uri(String path) => AppConstants.apiUri(path);

  Future<Map<String, dynamic>> get(
    String path, {
    bool authenticated = true,
  }) async {
    try {
      final response = await _client
          .get(_uri(path), headers: await _headers(authenticated))
          .timeout(const Duration(seconds: 15));
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
      final response = await _client
          .post(
            _uri(path),
            headers: await _headers(authenticated),
            body: jsonEncode(body ?? const <String, dynamic>{}),
          )
          .timeout(const Duration(seconds: 15));
      return _decode(response);
    } on TimeoutException {
      throw const ApiException('The API did not respond in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<Map<String, String>> _headers(bool authenticated) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (authenticated) {
      final accessToken = await _tokenStorage.getAccessToken();
      if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
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
