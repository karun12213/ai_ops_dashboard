import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../utils/app_constants.dart';
import 'token_storage.dart';

class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.existingUploadId,
    this.existingReportId,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final String? existingUploadId;
  final String? existingReportId;

  @override
  String toString() => message;
}

class ApiDownloadResponse {
  const ApiDownloadResponse({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });

  final Uint8List bytes;
  final String? filename;
  final String? contentType;
}

class ApiClient {
  ApiClient({
    http.Client? client,
    TokenStorage? tokenStorage,
    this.onSessionExpired,
  }) : _client = client ?? http.Client(),
       _tokenStorage = tokenStorage ?? TokenStorage();

  final http.Client _client;
  final TokenStorage _tokenStorage;
  final FutureOr<void> Function()? onSessionExpired;
  Future<bool>? _refreshInFlight;

  static const _requestTimeout = Duration(seconds: 15);
  // Sarvam batch jobs can legitimately outlive a short HTTP request. The
  // backend persists the provider job ID, so a browser retry can resume after
  // a disconnect without paying for another transcription.
  static const _uploadTimeout = Duration(minutes: 35);

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
    required String mediaType,
    Map<String, String> fields = const {},
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
            mediaType: mediaType,
            length: length,
            stream: openRead(),
            fields: fields,
            onProgress: onProgress,
          );
        },
      );
      return _decode(response);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('The upload did not complete in time.');
    } on http.ClientException {
      throw const ApiException(
        'Cannot reach the server. Check that the backend is running.',
        code: 'network_unreachable',
      );
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          'Audio multipart runtime failure: ${error.runtimeType}: $error\n$stackTrace',
        );
      }
      throw const ApiException(
        'The recording could not be processed.',
        code: 'multipart_runtime_failure',
      );
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
    String accept = 'application/octet-stream',
  }) async {
    try {
      final response = await _sendWithAuthRetry(
        authenticated: authenticated,
        send: (headers) =>
            _client.get(_uri(path), headers: {...headers, 'Accept': accept}),
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
        contentType: response.headers['content-type'],
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
    required String mediaType,
    required int length,
    required Stream<List<int>> stream,
    required Map<String, String> fields,
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
    final multipartHeaders = {...headers}..remove('Content-Type');
    request.headers.addAll(multipartHeaders);
    request.fields.addAll(fields);
    request.files.add(
      http.MultipartFile(
        fieldName,
        http.ByteStream(progressStream),
        length,
        filename: filename,
        contentType: MediaType.parse(mediaType),
      ),
    );
    if (kDebugMode) {
      debugPrint(
        'Audio multipart request: POST ${_uri(path)}; '
        'auth=${request.headers.containsKey('Authorization')}; '
        'fields=${fields.keys.join(',')}; filename=$filename; '
        'mime=$mediaType; bytes=$length',
      );
    }
    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (kDebugMode) {
      debugPrint('Audio multipart response: status=${response.statusCode}');
    }
    return response;
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
      await _notifySessionExpired();
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
      await _notifySessionExpired();
      return false;
    }
  }

  Future<void> _notifySessionExpired() async {
    try {
      await onSessionExpired?.call();
    } catch (_) {
      // Authentication state notification must never mask the HTTP result.
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
      final structured = detail is Map<String, dynamic> ? detail : null;
      final message = _errorMessage(
        response.statusCode,
        structured?['message'] ?? detail,
      );
      throw ApiException(
        message,
        statusCode: response.statusCode,
        code: structured?['code'] as String?,
        existingUploadId: structured?['existing_upload_id'] as String?,
        existingReportId: structured?['existing_report_id'] as String?,
      );
    }
    return payload;
  }

  static String _errorMessage(int statusCode, Object? detail) {
    if (statusCode >= 500) {
      return statusCode == 503
          ? 'A required service is temporarily unavailable. Please try again.'
          : 'The server could not complete the request. Please try again.';
    }
    if (detail is String && detail.isNotEmpty) return detail;
    return switch (statusCode) {
      401 => 'Your session has expired. Please sign in again.',
      404 => 'The requested resource was not found.',
      409 => 'This request conflicts with an existing record.',
      413 => 'The selected file is too large.',
      415 => 'The selected audio format is not supported.',
      422 => 'Some submitted information is invalid.',
      _ => 'The request could not be completed.',
    };
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
