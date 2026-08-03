import 'package:flutter/material.dart';

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.change,
    this.changeIsIncrease = true,
    this.changeIsFavorable = true,
  });

  final String label;
  final String value;
  final String? change;
  final IconData icon;
  final Color color;
  final bool changeIsIncrease;
  final bool changeIsFavorable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const Spacer(),
                if (change != null) ...[
                  Icon(
                    changeIsIncrease
                        ? Icons.trending_up_rounded
                        : Icons.trending_down_rounded,
                    color: changeIsFavorable ? scheme.primary : scheme.error,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    change!,
                    style: TextStyle(
                      color: changeIsFavorable ? scheme.primary : scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else
                  Text(
                    'No comparison',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
