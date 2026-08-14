import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/workspace_provider.dart';
import '../routes/app_router.dart';
import '../screens/workspace_setup_screen.dart';
import '../utils/app_constants.dart';
import 'app_navigation_drawer.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final wide =
        MediaQuery.sizeOf(context).width >= AppConstants.desktopBreakpoint;
    final user = ref.watch(authProvider).user;
    final workspaceState = ref.watch(workspaceProvider);
    final requiresWorkspace =
        location == AppRoutes.dashboard ||
        location == AppRoutes.reports ||
        location == AppRoutes.costAnalytics ||
        location == AppRoutes.audioUpload;

    return Scaffold(
      drawer: wide ? null : AppNavigationDrawer(currentLocation: location),
      appBar: AppBar(
        automaticallyImplyLeading: !wide,
        title: Text(_title(location)),
        actions: [
          if (workspaceState.hasReadyContext)
            _WorkspaceLocationSelector(state: workspaceState, compact: !wide),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: CircleAvatar(
              radius: 17,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                _initials(user?.fullName ?? 'Operator'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide) _NavigationRail(currentLocation: location),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppConstants.pageMaxWidth,
                ),
                child: requiresWorkspace
                    ? _workspaceBody(workspaceState, child)
                    : child,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _workspaceBody(WorkspaceState state, Widget child) {
    if (state.hasReadyContext) return child;
    if (state.isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Loading workspace access…'),
          ],
        ),
      );
    }
    if (state.loadError != null) {
      return _WorkspaceLoadError(message: state.loadError!);
    }
    return const WorkspaceSetupScreen();
  }

  static String _title(String location) => switch (location) {
    AppRoutes.reports => 'Reports',
    AppRoutes.costAnalytics => 'Cost Analytics',
    AppRoutes.audioUpload => 'Audio upload',
    AppRoutes.settings => 'Settings',
    _ => 'Dashboard',
  };

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts
        .take(2)
        .where((part) => part.isNotEmpty)
        .map((part) => part[0])
        .join()
        .toUpperCase();
  }
}

class _WorkspaceLocationSelector extends ConsumerWidget {
  const _WorkspaceLocationSelector({
    required this.state,
    required this.compact,
  });

  final WorkspaceState state;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeWorkspace = state.activeWorkspace!;
    final activeLocation = state.activeLocation!;
    return PopupMenuButton<({String workspaceId, String locationId})>(
      key: const Key('workspace-location-selector'),
      tooltip: 'Change workspace location',
      onSelected: (selection) {
        ref
            .read(workspaceProvider.notifier)
            .selectLocation(
              workspaceId: selection.workspaceId,
              locationId: selection.locationId,
            );
      },
      itemBuilder: (context) => [
        for (final workspace in state.workspaces)
          for (final location in workspace.locations)
            PopupMenuItem(
              value: (workspaceId: workspace.id, locationId: location.id),
              child: Row(
                children: [
                  Icon(
                    workspace.id == activeWorkspace.id &&
                            location.id == activeLocation.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(location.name),
                        Text(
                          workspace.name,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compact ? 150 : 260),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_outlined, size: 18),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  compact
                      ? activeLocation.name
                      : '${activeWorkspace.name} · ${activeLocation.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceLoadError extends ConsumerWidget {
  const _WorkspaceLoadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unauthorized = message.startsWith('Your session has expired');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.domain_disabled_outlined,
              size: 46,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 14),
            Text(
              unauthorized
                  ? 'Session expired'
                  : 'Workspace access is unavailable',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(message),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('workspace-load-retry-button'),
              onPressed: unauthorized
                  ? ref.read(authProvider.notifier).logout
                  : ref.read(workspaceProvider.notifier).load,
              icon: Icon(
                unauthorized ? Icons.login_rounded : Icons.refresh_rounded,
              ),
              label: Text(unauthorized ? 'Sign in again' : 'Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationRail extends StatelessWidget {
  const _NavigationRail({required this.currentLocation});

  final String currentLocation;

  @override
  Widget build(BuildContext context) {
    final destinations = AppNavigationDrawer.destinations;
    final selected = destinations.indexWhere(
      (item) => item.route == currentLocation,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: NavigationRail(
        minExtendedWidth: 230,
        extended: true,
        selectedIndex: selected < 0 ? 0 : selected,
        leading: const Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: _RailBrand(),
        ),
        onDestinationSelected: (index) => context.go(destinations[index].route),
        destinations: [
          for (final item in destinations)
            NavigationRailDestination(
              icon: Icon(item.icon),
              label: Text(item.label),
            ),
        ],
      ),
    );
  }
}

class _RailBrand extends StatelessWidget {
  const _RailBrand();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 198,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.restaurant_menu_rounded,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Restaurant Ops',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
