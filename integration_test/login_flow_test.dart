import 'package:ai_ops_dashboard/app.dart';
import 'package:ai_ops_dashboard/providers/auth_provider.dart';
import 'package:ai_ops_dashboard/services/token_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const email = String.fromEnvironment('E2E_EMAIL');
  const password = String.fromEnvironment('E2E_PASSWORD');

  testWidgets('logs in against the running FastAPI backend', (tester) async {
    if (email.isEmpty || password.isEmpty) {
      fail('Pass E2E_EMAIL and E2E_PASSWORD with --dart-define.');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.clear();

    await tester.pumpWidget(const ProviderScope(child: RestaurantOpsApp()));
    await _pumpUntil(
      tester,
      () => find.text('Welcome back').evaluate().isNotEmpty,
    );

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), email);
    await tester.enterText(fields.at(1), password);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));

    await _pumpUntil(tester, () {
      final context = tester.element(find.byType(RestaurantOpsApp));
      return ProviderScope.containerOf(
            context,
            listen: false,
          ).read(authProvider).status ==
          AuthStatus.authenticated;
    });

    expect(find.text('Good service starts here'), findsOneWidget);
    expect(find.text('Authentication service unavailable'), findsNothing);

    final tokenStorage = TokenStorage();
    expect((await tokenStorage.getAccessToken())?.isNotEmpty, isTrue);
    expect((await tokenStorage.getRefreshToken())?.isNotEmpty, isTrue);

    // Replace the access token with an invalid/expired equivalent while
    // preserving the real refresh token. A fresh provider tree must receive
    // /auth/me 401, rotate through /auth/refresh, retry /auth/me once, and
    // remain on the authenticated dashboard.
    await tokenStorage.saveTokens(
      accessToken: 'integration-test-expired-access-token',
      refreshToken: (await tokenStorage.getRefreshToken())!,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(const ProviderScope(child: RestaurantOpsApp()));
    await _pumpUntil(
      tester,
      () => find.text('Good service starts here').evaluate().isNotEmpty,
    );
    expect(find.text('Welcome back'), findsNothing);
    expect(
      await tokenStorage.getAccessToken(),
      isNot('integration-test-expired-access-token'),
    );
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('Timed out waiting for the application state.');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  // The condition is the synchronization point. A final bounded pump renders
  // the matching state without letting unrelated plugin/framework activity
  // keep the end-to-end test waiting indefinitely during teardown.
  await tester.pump(const Duration(milliseconds: 100));
}
