class DevelopmentLoginConfig {
  const DevelopmentLoginConfig({
    required this.appEnvironment,
    required this.email,
    required this.password,
  });

  const DevelopmentLoginConfig.fromDartDefines()
    : appEnvironment = const String.fromEnvironment('APP_ENV'),
      email = const String.fromEnvironment('DEV_LOGIN_EMAIL'),
      password = const String.fromEnvironment('DEV_LOGIN_PASSWORD');

  final String appEnvironment;
  final String email;
  final String password;

  bool get isEnabled =>
      appEnvironment == 'development' &&
      email.trim().isNotEmpty &&
      password.isNotEmpty;

  bool matches({required String email, required String password}) {
    if (!isEnabled) return false;
    return email.trim().toLowerCase() == this.email.trim().toLowerCase() &&
        password == this.password;
  }
}
