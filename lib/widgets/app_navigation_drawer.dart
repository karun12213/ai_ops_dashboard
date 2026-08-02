import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routes/app_router.dart';

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({super.key, required this.currentLocation});

  final String currentLocation;

  static const destinations = <_Destination>[
    _Destination('Dashboard', Icons.grid_view_rounded, AppRoutes.dashboard),
    _Destination('Reports', Icons.analytics_outlined, AppRoutes.reports),
    _Destination(
      'Audio upload',
      Icons.graphic_eq_rounded,
      AppRoutes.audioUpload,
    ),
    _Destination('Settings', Icons.tune_rounded, AppRoutes.settings),
  ];

  @override
  Widget build(BuildContext context) {
    return Drawer(
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: [
            const _Brand(),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: destinations.length,
                separatorBuilder: (context, index) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final item = destinations[index];
                  return ListTile(
                    selected: currentLocation == item.route,
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      context.go(item.route);
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'FOUNDATION  •  v1.0',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.restaurant_menu_rounded,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Restaurant Ops',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              Text('Operations workspace', style: TextStyle(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.route);

  final String label;
  final IconData icon;
  final String route;
}
