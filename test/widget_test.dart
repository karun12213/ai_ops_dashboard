import 'dart:async';

import 'package:ai_ops_dashboard/app.dart';
import 'package:ai_ops_dashboard/models/user.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/auth_provider.dart';
import 'package:ai_ops_dashboard/providers/dashboard_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/screens/login_screen.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/auth_service.dart';
import 'package:ai_ops_dashboard/services/dashboard_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:ai_ops_dashboard/models/dashboard_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows validation only after interaction or submission', (
    tester,
  ) async {
    final authService = _FakeAuthService();
    await _pumpLoginApp(tester, authService);

    expect(find.text('Email is required'), findsNothing);
    expect(find.text('Password is required'), findsNothing);
    expect(find.text('Incorrect email or password.'), findsNothing);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'invalid-email');
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Password is required'), findsNothing);

    await tester.enterText(fields.at(0), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
    expect(find.text('Incorrect email or password.'), findsNothing);
    expect(authService.loginCalls, 0);
  });

  testWidgets('shows a failed login error until either field is edited', (
    tester,
  ) async {
    final authService = _FakeAuthService(
      onLogin: ({required email, required password}) async {
        throw const InvalidCredentialsException();
      },
    );
    await _pumpLoginApp(tester, authService);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'operator@example.com');
    await tester.enterText(fields.at(1), 'not-the-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect email or password.'), findsOneWidget);
    expect(find.text('Email is required'), findsNothing);
    expect(find.text('Password is required'), findsNothing);
    expect(
      tester.widget<TextFormField>(fields.at(0)).controller?.text,
      'operator@example.com',
    );
    expect(
      tester.widget<TextFormField>(fields.at(1)).controller?.text,
      'not-the-password',
    );

    await tester.enterText(fields.at(0), 'updated@example.com');
    await tester.pump();
    expect(find.text('Incorrect email or password.'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect email or password.'), findsOneWidget);

    await tester.enterText(fields.at(1), 'another-password');
    await tester.pump();
    expect(find.text('Incorrect email or password.'), findsNothing);
  });

  final loginErrorCases = <({int? statusCode, String expected})>[
    (statusCode: null, expected: 'Authentication service unavailable'),
    (
      statusCode: 401,
      expected: 'Sign in could not be completed. Please try again.',
    ),
    (
      statusCode: 403,
      expected: 'This account is disabled. Contact an administrator.',
    ),
    (statusCode: 429, expected: 'Too many attempts'),
    (statusCode: 500, expected: 'Server error'),
  ];

  for (final errorCase in loginErrorCases) {
    testWidgets('maps login status ${errorCase.statusCode} to a safe message', (
      tester,
    ) async {
      final authService = _FakeAuthService(
        onLogin: ({required email, required password}) async {
          throw ApiException(
            'Potentially unsafe backend detail',
            statusCode: errorCase.statusCode,
          );
        },
      );
      await _pumpLoginApp(tester, authService);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'operator@example.com');
      await tester.enterText(fields.at(1), 'not-the-password');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text(errorCase.expected), findsOneWidget);
      expect(find.text('Incorrect email or password.'), findsNothing);
      expect(find.text('Potentially unsafe backend detail'), findsNothing);
    });
  }

  testWidgets('disables sign in and shows progress during login', (
    tester,
  ) async {
    final loginCompleter = Completer<User>();
    final authService = _FakeAuthService(
      onLogin: ({required email, required password}) => loginCompleter.future,
    );
    await _pumpLoginApp(tester, authService);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'operator@example.com');
    await tester.enterText(fields.at(1), 'correct-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    loginCompleter.complete(_user);
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Good service starts here'), findsOneWidget);
  });
}

const _user = User(
  id: 'user-id',
  email: 'operator@example.com',
  fullName: 'Test Operator',
  isActive: true,
  isSuperuser: false,
);

typedef _LoginCallback =
    Future<User> Function({required String email, required String password});

class _FakeAuthService implements AuthService {
  _FakeAuthService({this.onLogin});

  final _LoginCallback? onLogin;
  int loginCalls = 0;

  @override
  Future<User> login({required String email, required String password}) {
    loginCalls += 1;
    final callback = onLogin;
    if (callback == null) {
      throw StateError('Login should not have been called.');
    }
    return callback(email: email, password: password);
  }

  @override
  Future<User?> restoreSession() async => null;

  @override
  Future<void> logout() async {}

  @override
  Future<User> currentUser() => throw UnimplementedError();
}

Future<void> _pumpLoginApp(WidgetTester tester, AuthService authService) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => AuthNotifier(authService)),
        dashboardServiceProvider.overrideWith(
          (ref) => _EmptyDashboardService(),
        ),
        workspaceProvider.overrideWith(
          (ref) => WorkspaceNotifier(
            _UnusedWorkspaceRepository(),
            loadOnCreate: false,
            initialState: _workspaceState,
          ),
        ),
      ],
      child: const RestaurantOpsApp(),
    ),
  );
  await tester.pumpAndSettle();

  expect(find.byType(LoginScreen), findsOneWidget);
}

class _EmptyDashboardService implements DashboardService {
  @override
  Future<DashboardData> fetch({
    required DateTime serviceDate,
    required String workspaceId,
    required String locationId,
    int activityLimit = 10,
  }) async {
    return DashboardData(
      serviceDate: serviceDate,
      snapshot: null,
      recentActivity: const [],
    );
  }
}

const _workspaceState = WorkspaceState(
  workspaces: [
    WorkspaceAccess(
      id: 'workspace-1',
      name: 'Restaurant',
      role: WorkspaceRole.owner,
      locations: [
        WorkspaceLocation(
          id: 'location-1',
          name: 'Main Floor',
          currencyCode: 'INR',
        ),
      ],
    ),
  ],
  activeWorkspaceId: 'workspace-1',
  activeLocationId: 'location-1',
  isLoading: false,
);

class _UnusedWorkspaceRepository implements WorkspaceRepository {
  @override
  Future<WorkspaceContext> fetchContext() => throw UnimplementedError();

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) => throw UnimplementedError();
}
