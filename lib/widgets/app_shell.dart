import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../routes/app_router.dart';
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

    return Scaffold(
      drawer: wide ? null : AppNavigationDrawer(currentLocation: location),
      appBar: AppBar(
        automaticallyImplyLeading: !wide,
        title: Text(_title(location)),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () {},
            icon: const Badge(
              smallSize: 7,
              child: Icon(Icons.notifications_none_rounded),
            ),
          ),
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
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _title(String location) => switch (location) {
    AppRoutes.reports => 'Reports',
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
