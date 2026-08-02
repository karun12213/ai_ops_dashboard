abstract final class AppConstants {
  static const appName = 'Restaurant Ops';
  static const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static String get apiBaseUrl {
    final configured = _configuredApiBaseUrl.trim();
    if (configured.isNotEmpty) {
      return configured.replaceFirst(RegExp(r'/+$'), '');
    }

    // Use the same host that served Flutter so localhost, 127.0.0.1, and LAN
    // development URLs all reach the API on the current machine.
    final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
    return Uri(
      scheme: Uri.base.scheme == 'https' ? 'https' : 'http',
      host: host,
      port: 8000,
      path: '/api/v1',
    ).toString();
  }

  static Uri apiUri(String path) {
    final base = Uri.base.resolve(
      '${apiBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
    );
    return base.resolve(path.replaceFirst(RegExp(r'^/+'), ''));
  }

  static const desktopBreakpoint = 1100.0;
  static const tabletBreakpoint = 700.0;
  static const pageMaxWidth = 1480.0;
}
