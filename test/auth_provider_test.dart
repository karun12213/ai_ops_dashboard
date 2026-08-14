import 'package:ai_ops_dashboard/config/development_login_config.dart';
import 'package:ai_ops_dashboard/models/user.dart';
import 'package:ai_ops_dashboard/providers/auth_provider.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const developmentConfig = DevelopmentLoginConfig(
    appEnvironment: 'development',
    email: 'developer@example.test',
    password: 'development-password',
  );

  test('backend login success creates a backend session', () async {
    final authService = _FakeAuthService(onLogin: (_) async => _backendUser);
    final notifier = AuthNotifier(authService, developmentConfig);
    addTearDown(notifier.dispose);

    final succeeded = await notifier.login(
      email: 'operator@example.test',
      password: 'backend-password',
    );

    expect(succeeded, isTrue);
    expect(authService.loginCalls, 1);
    expect(notifier.state.status, AuthStatus.authenticated);
    expect(notifier.state.user, same(_backendUser));
    expect(notifier.state.sessionType, AuthSessionType.backend);
    expect(notifier.state.isDevelopmentSession, isFalse);
  });

  test(
    'backend unavailability permits the configured development login',
    () async {
      final authService = _FakeAuthService(
        onLogin: (_) async => throw const ApiException('API unavailable'),
      );
      final notifier = AuthNotifier(authService, developmentConfig);
      addTearDown(notifier.dispose);

      final succeeded = await notifier.login(
        email: ' developer@example.test ',
        password: 'development-password',
      );

      expect(succeeded, isTrue);
      expect(authService.loginCalls, 1);
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 'development-session');
      expect(notifier.state.user?.email, 'developer@example.test');
      expect(notifier.state.sessionType, AuthSessionType.development);
      expect(notifier.state.isDevelopmentSession, isTrue);
      expect(notifier.state.errorMessage, isNull);
    },
  );

  test('wrong development credentials are rejected', () async {
    final authService = _FakeAuthService(
      onLogin: (_) async => throw const ApiException('API unavailable'),
    );
    final notifier = AuthNotifier(authService, developmentConfig);
    addTearDown(notifier.dispose);

    final succeeded = await notifier.login(
      email: 'developer@example.test',
      password: 'wrong-password',
    );

    expect(succeeded, isFalse);
    expect(authService.loginCalls, 1);
    expect(notifier.state.status, AuthStatus.unauthenticated);
    expect(notifier.state.user, isNull);
    expect(notifier.state.sessionType, isNull);
    expect(notifier.state.errorMessage, 'Incorrect email or password.');
  });

  test('development fallback is disabled outside development', () async {
    final authService = _FakeAuthService(
      onLogin: (_) async => throw const ApiException('API unavailable'),
    );
    final notifier = AuthNotifier(
      authService,
      const DevelopmentLoginConfig(
        appEnvironment: 'production',
        email: 'developer@example.test',
        password: 'development-password',
      ),
    );
    addTearDown(notifier.dispose);

    final succeeded = await notifier.login(
      email: 'developer@example.test',
      password: 'development-password',
    );

    expect(succeeded, isFalse);
    expect(authService.loginCalls, 1);
    expect(notifier.state.status, AuthStatus.unauthenticated);
    expect(notifier.state.user, isNull);
    expect(notifier.state.sessionType, isNull);
    expect(notifier.state.errorMessage, 'Authentication service unavailable');
  });

  test(
    'session expiry clears authenticated state with the required message',
    () async {
      final authService = _FakeAuthService(onLogin: (_) async => _backendUser);
      final notifier = AuthNotifier(authService, developmentConfig);
      addTearDown(notifier.dispose);
      await notifier.login(
        email: 'operator@example.test',
        password: 'password',
      );

      notifier.sessionExpired();

      expect(notifier.state.status, AuthStatus.unauthenticated);
      expect(notifier.state.user, isNull);
      expect(
        notifier.state.errorMessage,
        'Your session has expired. Please sign in again.',
      );
    },
  );
}

const _backendUser = User(
  id: 'backend-user',
  email: 'operator@example.test',
  fullName: 'Backend Operator',
  isActive: true,
  isSuperuser: false,
);

typedef _LoginCallback =
    Future<User> Function(({String email, String password}) credentials);

class _FakeAuthService implements AuthService {
  _FakeAuthService({required this.onLogin});

  final _LoginCallback onLogin;
  int loginCalls = 0;

  @override
  Future<User> login({required String email, required String password}) {
    loginCalls += 1;
    return onLogin((email: email, password: password));
  }

  @override
  Future<User?> restoreSession() async => null;

  @override
  Future<void> logout() async {}

  @override
  Future<User> currentUser() => throw UnimplementedError();
}
