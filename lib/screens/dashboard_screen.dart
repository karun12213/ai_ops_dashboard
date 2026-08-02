import 'package:flutter/material.dart';

import '../widgets/page_header.dart';
import '../widgets/stat_card.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Good service starts here',
            description: 'A live operational snapshot for Saturday, August 1.',
            action: OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: const Text('Today'),
            ),
          ),
          const SizedBox(height: 28),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1150
                  ? 4
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              const gap = 16.0;
              final width =
                  (constraints.maxWidth - (columns - 1) * gap) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: width,
                    child: const StatCard(
                      label: 'Net sales',
                      value: '₹2,84,120',
                      change: '12.4%',
                      icon: Icons.payments_outlined,
                      color: Color(0xFF42D3A5),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: const StatCard(
                      label: 'Orders served',
                      value: '418',
                      change: '8.1%',
                      icon: Icons.receipt_long_outlined,
                      color: Color(0xFF64B5F6),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: const StatCard(
                      label: 'Average ticket',
                      value: '₹680',
                      change: '3.7%',
                      icon: Icons.point_of_sale_outlined,
                      color: Color(0xFFFFB74D),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: const StatCard(
                      label: 'Table turn time',
                      value: '47 min',
                      change: '5.2%',
                      icon: Icons.timer_outlined,
                      color: Color(0xFFCE93D8),
                      positive: true,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 850;
              final children = [const _SalesOverview(), const _ServicePulse()];
              if (stacked) {
                return Column(
                  children: [
                    children[0],
                    const SizedBox(height: 16),
                    children[1],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: children[0]),
                  const SizedBox(width: 16),
                  Expanded(child: children[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          const _RecentActivity(),
        ],
      ),
    );
  }
}

class _SalesOverview extends StatelessWidget {
  const _SalesOverview();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const points = [
      0.28,
      0.42,
      0.38,
      0.61,
      0.55,
      0.78,
      0.69,
      0.88,
      0.76,
      0.94,
      0.86,
      1.0,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sales overview',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Hourly net sales',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const Chip(label: Text('Open service')),
              ],
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 210,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var index = 0; index < points.length; index++) ...[
                    Expanded(
                      child: Tooltip(
                        message: '${10 + index}:00',
                        child: FractionallySizedBox(
                          heightFactor: points[index],
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            decoration: BoxDecoration(
                              color: index == points.length - 1
                                  ? scheme.primary
                                  : scheme.primary.withValues(alpha: 0.35),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(6),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (index < points.length - 1) const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: ['10 AM', '2 PM', '6 PM', '9 PM']
                  .map(
                    (label) => Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServicePulse extends StatelessWidget {
  const _ServicePulse();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Service pulse',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Current floor status',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 25),
            const _PulseItem(
              label: 'Dining room',
              detail: '18 of 24 tables',
              value: 0.75,
              color: Color(0xFF42D3A5),
            ),
            const SizedBox(height: 22),
            const _PulseItem(
              label: 'Kitchen load',
              detail: '14 active tickets',
              value: 0.62,
              color: Color(0xFFFFB74D),
            ),
            const SizedBox(height: 22),
            const _PulseItem(
              label: 'Pickup queue',
              detail: '6 orders',
              value: 0.35,
              color: Color(0xFF64B5F6),
            ),
            const SizedBox(height: 22),
            const _PulseItem(
              label: 'Staff on shift',
              detail: '21 of 23',
              value: 0.91,
              color: Color(0xFFCE93D8),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseItem extends StatelessWidget {
  const _PulseItem({
    required this.label,
    required this.detail,
    required this.value,
    required this.color,
  });

  final String label;
  final String detail;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              detail,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        LinearProgressIndicator(
          value: value,
          minHeight: 7,
          borderRadius: BorderRadius.circular(8),
          color: color,
        ),
      ],
    );
  }
}

class _RecentActivity extends StatelessWidget {
  const _RecentActivity();

  @override
  Widget build(BuildContext context) {
    const rows = [
      (
        'Dinner shift opened',
        'Floor Manager',
        '5:02 PM',
        Icons.door_front_door_outlined,
      ),
      (
        'Inventory count submitted',
        'Kitchen Team',
        '4:28 PM',
        Icons.inventory_2_outlined,
      ),
      (
        'Daily report exported',
        'Operations',
        '3:46 PM',
        Icons.file_download_outlined,
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent activity',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < rows.length; index++) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Icon(rows[index].$4, size: 20)),
                title: Text(rows[index].$1),
                subtitle: Text(rows[index].$2),
                trailing: Text(rows[index].$3),
              ),
              if (index < rows.length - 1) const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}
