import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

class ApiDownloadResponse {
  const ApiDownloadResponse({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String? filename;
}

class ApiClient {
  ApiClient({http.Client? client, TokenStorage? tokenStorage})
    : _client = client ?? http.Client(),
      _tokenStorage = tokenStorage ?? TokenStorage();

  final http.Client _client;
  final TokenStorage _tokenStorage;
  Future<bool>? _refreshInFlight;

  static const _requestTimeout = Duration(seconds: 15);
  static const _uploadTimeout = Duration(minutes: 5);

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

  Future<Map<String, dynamic>> multipartPost(
    String path, {
    required String fieldName,
    required String filename,
    required int length,
    required Stream<List<int>> Function() openRead,
    void Function(double progress)? onProgress,
    bool authenticated = true,
  }) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        timeout: _uploadTimeout,
        send: (headers) {
          onProgress?.call(0);
          return _sendMultipart(
            path: path,
            headers: headers,
            fieldName: fieldName,
            filename: filename,
            length: length,
            stream: openRead(),
            onProgress: onProgress,
          );
        },
      );
      return _decode(response);
    } on TimeoutException {
      throw const ApiException('The upload did not complete in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<void> delete(String path, {bool authenticated = true}) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        send: (headers) => _client.delete(_uri(path), headers: headers),
      );
      _decode(response);
    } on TimeoutException {
      throw const ApiException('The API did not respond in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<ApiDownloadResponse> download(
    String path, {
    bool authenticated = true,
  }) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        send: (headers) => _client.get(
          _uri(path),
          headers: {...headers, 'Accept': 'text/csv'},
        ),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _decode(response);
        throw ApiException(
          'The request could not be completed.',
          statusCode: response.statusCode,
        );
      }
      return ApiDownloadResponse(
        bytes: response.bodyBytes,
        filename: _responseFilename(response.headers['content-disposition']),
      );
    } on TimeoutException {
      throw const ApiException('The API did not respond in time.');
    } on http.ClientException {
      throw const ApiException('Unable to reach the API.');
    }
  }

  Future<http.Response> _sendWithAuthRetry({
    required bool authenticated,
    required Future<http.Response> Function(Map<String, String> headers) send,
    Duration timeout = _requestTimeout,
  }) async {
    final initial = await _headers(authenticated);
    final response = await send(initial.headers).timeout(timeout);
    if (!authenticated || response.statusCode != 401) return response;

    // Another request may already have completed a refresh after this request
    // left with the old access token. Reuse that newer token before starting a
    // second rotation.
    final currentAccessToken = await _tokenStorage.getAccessToken();
    if (initial.accessToken != null &&
        currentAccessToken != null &&
        currentAccessToken != initial.accessToken) {
      final retryHeaders = await _headers(true);
      return send(retryHeaders.headers).timeout(timeout);
    }

    if (!await refreshAccessToken()) return response;
    final retryHeaders = await _headers(true);
    return send(retryHeaders.headers).timeout(timeout);
  }

  Future<http.Response> _sendMultipart({
    required String path,
    required Map<String, String> headers,
    required String fieldName,
    required String filename,
    required int length,
    required Stream<List<int>> stream,
    void Function(double progress)? onProgress,
  }) async {
    if (length <= 0) throw const ApiException('The selected file is empty.');
    var bytesSent = 0;
    final progressStream = stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          bytesSent += chunk.length;
          onProgress?.call((bytesSent / length).clamp(0, 1));
          sink.add(chunk);
        },
      ),
    );
    final request = http.MultipartRequest('POST', _uri(path));
    request.headers.addAll(headers..remove('Content-Type'));
    request.files.add(
      http.MultipartFile(
        fieldName,
        http.ByteStream(progressStream),
        length,
        filename: filename,
      ),
    );
    final streamedResponse = await _client.send(request);
    return http.Response.fromStream(streamedResponse);
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

  static String? _responseFilename(String? contentDisposition) {
    if (contentDisposition == null) return null;
    final match = RegExp(
      r'filename="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    return match?.group(1);
  }
}
