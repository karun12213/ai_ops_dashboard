import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/development_login_config.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/token_storage.dart';

enum AuthStatus { loading, authenticated, unauthenticated }

enum AuthSessionType { backend, development }

class AuthState {
  const AuthState({
    required this.status,
    this.user,
    this.errorMessage,
    this.sessionType,
  });

  const AuthState.loading() : this(status: AuthStatus.loading);

  final AuthStatus status;
  final User? user;
  final String? errorMessage;
  final AuthSessionType? sessionType;

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isDevelopmentSession => sessionType == AuthSessionType.development;
}

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(tokenStorage: ref.watch(tokenStorageProvider));
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  );
});

final developmentLoginConfigProvider = Provider<DevelopmentLoginConfig>((ref) {
  return const DevelopmentLoginConfig.fromDartDefines();
});

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authServiceProvider),
    ref.watch(developmentLoginConfigProvider),
  );
});

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(
    this._authService, [
    this._developmentLoginConfig =
        const DevelopmentLoginConfig.fromDartDefines(),
  ]) : super(const AuthState.loading()) {
    restoreSession();
  }

  final AuthService _authService;
  final DevelopmentLoginConfig _developmentLoginConfig;

  Future<void> restoreSession() async {
    try {
      final user = await _authService.restoreSession();
      if (!mounted) return;
      state = user == null
          ? const AuthState(status: AuthStatus.unauthenticated)
          : AuthState(
              status: AuthStatus.authenticated,
              user: user,
              sessionType: AuthSessionType.backend,
            );
    } catch (_) {
      if (mounted) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    }
  }

  Future<bool> login({required String email, required String password}) async {
    state = const AuthState.loading();
    try {
      final user = await _authService.login(email: email, password: password);
      if (!mounted) return false;
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        sessionType: AuthSessionType.backend,
      );
      return true;
    } on InvalidCredentialsException {
      if (!mounted) return false;
      state = const AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: 'Incorrect email or password.',
      );
      return false;
    } on ApiException catch (error) {
      if (!mounted) return false;
      if (error.statusCode == null && _developmentLoginConfig.isEnabled) {
        if (_developmentLoginConfig.matches(email: email, password: password)) {
          state = AuthState(
            status: AuthStatus.authenticated,
            user: User(
              id: 'development-session',
              email: _developmentLoginConfig.email.trim().toLowerCase(),
              fullName: 'Development Administrator',
              isActive: true,
              isSuperuser: true,
            ),
            sessionType: AuthSessionType.development,
          );
          return true;
        }

        state = const AuthState(
          status: AuthStatus.unauthenticated,
          errorMessage: 'Incorrect email or password.',
        );
        return false;
      }
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: _loginErrorMessage(error.statusCode),
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      state = const AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: 'Sign in could not be completed. Please try again.',
      );
      return false;
    }
  }

  static String _loginErrorMessage(int? statusCode) {
    if (statusCode == 403) {
      return 'This account is disabled. Contact an administrator.';
    }
    if (statusCode == 429) return 'Too many attempts';
    if (statusCode == 500 || (statusCode != null && statusCode > 500)) {
      return 'Server error';
    }
    if (statusCode == null) return 'Authentication service unavailable';
    return 'Sign in could not be completed. Please try again.';
  }

  void clearLoginError() {
    if (state.errorMessage == null) return;
    state = AuthState(
      status: state.status,
      user: state.user,
      sessionType: state.sessionType,
    );
  }

  Future<void> logout() async {
    await _authService.logout();
    if (mounted) state = const AuthState(status: AuthStatus.unauthenticated);
  }
}
