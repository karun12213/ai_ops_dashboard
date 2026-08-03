class DashboardData {
  const DashboardData({
    required this.serviceDate,
    required this.snapshot,
    required this.recentActivity,
  });

  final DateTime serviceDate;
  final DashboardSnapshot? snapshot;
  final List<DashboardActivity> recentActivity;

  factory DashboardData.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    final activity = json['recent_activity'];
    if (activity is! List) {
      throw const FormatException('Invalid Dashboard activity response.');
    }
    return DashboardData(
      serviceDate: DateTime.parse(_stringValue(json, 'service_date')),
      snapshot: snapshot == null
          ? null
          : DashboardSnapshot.fromJson(_mapValue(snapshot, 'snapshot')),
      recentActivity: activity
          .map(
            (item) => DashboardActivity.fromJson(
              _mapValue(item, 'recent_activity item'),
            ),
          )
          .toList(growable: false),
    );
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.updatedAt,
    required this.serviceOpen,
    required this.metrics,
    required this.hourlySales,
    required this.servicePulse,
  });

  final DateTime updatedAt;
  final bool serviceOpen;
  final DashboardMetrics metrics;
  final List<DashboardHourlySales> hourlySales;
  final DashboardServicePulse servicePulse;

  factory DashboardSnapshot.fromJson(Map<String, dynamic> json) {
    final hourlySales = json['hourly_sales'];
    if (hourlySales is! List) {
      throw const FormatException('Invalid hourly sales response.');
    }
    return DashboardSnapshot(
      updatedAt: DateTime.parse(_stringValue(json, 'updated_at')),
      serviceOpen: _boolValue(json, 'service_open'),
      metrics: DashboardMetrics.fromJson(_mapValue(json['metrics'], 'metrics')),
      hourlySales: hourlySales
          .map(
            (item) => DashboardHourlySales.fromJson(
              _mapValue(item, 'hourly_sales item'),
            ),
          )
          .toList(growable: false),
      servicePulse: DashboardServicePulse.fromJson(
        _mapValue(json['service_pulse'], 'service_pulse'),
      ),
    );
  }
}

class DashboardMetrics {
  const DashboardMetrics({
    required this.currencyCode,
    required this.netSalesMinor,
    required this.netSalesChangePercent,
    required this.ordersServed,
    required this.ordersChangePercent,
    required this.averageTicketMinor,
    required this.averageTicketChangePercent,
    required this.averageTableTurnMinutes,
    required this.tableTurnChangePercent,
  });

  final String currencyCode;
  final int netSalesMinor;
  final double? netSalesChangePercent;
  final int ordersServed;
  final double? ordersChangePercent;
  final int averageTicketMinor;
  final double? averageTicketChangePercent;
  final int? averageTableTurnMinutes;
  final double? tableTurnChangePercent;

  factory DashboardMetrics.fromJson(Map<String, dynamic> json) {
    return DashboardMetrics(
      currencyCode: _stringValue(json, 'currency_code'),
      netSalesMinor: _intValue(json, 'net_sales_minor'),
      netSalesChangePercent: _nullableDoubleValue(
        json,
        'net_sales_change_percent',
      ),
      ordersServed: _intValue(json, 'orders_served'),
      ordersChangePercent: _nullableDoubleValue(json, 'orders_change_percent'),
      averageTicketMinor: _intValue(json, 'average_ticket_minor'),
      averageTicketChangePercent: _nullableDoubleValue(
        json,
        'average_ticket_change_percent',
      ),
      averageTableTurnMinutes: _nullableIntValue(
        json,
        'average_table_turn_minutes',
      ),
      tableTurnChangePercent: _nullableDoubleValue(
        json,
        'table_turn_change_percent',
      ),
    );
  }
}

class DashboardHourlySales {
  const DashboardHourlySales({required this.hour, required this.netSalesMinor});

  final int hour;
  final int netSalesMinor;

  factory DashboardHourlySales.fromJson(Map<String, dynamic> json) {
    return DashboardHourlySales(
      hour: _intValue(json, 'hour'),
      netSalesMinor: _intValue(json, 'net_sales_minor'),
    );
  }
}

class DashboardServicePulse {
  const DashboardServicePulse({
    required this.occupiedTables,
    required this.totalTables,
    required this.activeKitchenTickets,
    required this.kitchenCapacity,
    required this.pickupOrders,
    required this.pickupCapacity,
    required this.staffOnShift,
    required this.staffScheduled,
  });

  final int occupiedTables;
  final int totalTables;
  final int activeKitchenTickets;
  final int kitchenCapacity;
  final int pickupOrders;
  final int pickupCapacity;
  final int staffOnShift;
  final int staffScheduled;

  factory DashboardServicePulse.fromJson(Map<String, dynamic> json) {
    return DashboardServicePulse(
      occupiedTables: _intValue(json, 'occupied_tables'),
      totalTables: _intValue(json, 'total_tables'),
      activeKitchenTickets: _intValue(json, 'active_kitchen_tickets'),
      kitchenCapacity: _intValue(json, 'kitchen_capacity'),
      pickupOrders: _intValue(json, 'pickup_orders'),
      pickupCapacity: _intValue(json, 'pickup_capacity'),
      staffOnShift: _intValue(json, 'staff_on_shift'),
      staffScheduled: _intValue(json, 'staff_scheduled'),
    );
  }
}

class DashboardActivity {
  const DashboardActivity({
    required this.id,
    required this.occurredAt,
    required this.title,
    required this.actor,
    required this.category,
  });

  final String id;
  final DateTime occurredAt;
  final String title;
  final String actor;
  final String category;

  factory DashboardActivity.fromJson(Map<String, dynamic> json) {
    return DashboardActivity(
      id: _stringValue(json, 'id'),
      occurredAt: DateTime.parse(_stringValue(json, 'occurred_at')),
      title: _stringValue(json, 'title'),
      actor: _stringValue(json, 'actor'),
      category: _stringValue(json, 'category'),
    );
  }
}

Map<String, dynamic> _mapValue(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Invalid $field response.');
}

String _stringValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Invalid $field response.');
}

int _intValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is num) return value.toInt();
  throw FormatException('Invalid $field response.');
}

int? _nullableIntValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is num) return value.toInt();
  throw FormatException('Invalid $field response.');
}

double? _nullableDoubleValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw FormatException('Invalid $field response.');
}

bool _boolValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is bool) return value;
  throw FormatException('Invalid $field response.');
}
