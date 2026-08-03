class ReportData {
  const ReportData({
    required this.startDate,
    required this.endDate,
    required this.locationId,
    required this.locations,
    required this.totals,
    required this.channelSplit,
    required this.revenueTrend,
    required this.locationPerformance,
  });

  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;
  final List<ReportLocation> locations;
  final ReportTotals totals;
  final List<ReportChannel> channelSplit;
  final List<ReportTrendPoint> revenueTrend;
  final List<ReportLocationPerformance> locationPerformance;

  bool get hasData =>
      channelSplit.isNotEmpty ||
      revenueTrend.isNotEmpty ||
      locationPerformance.isNotEmpty;

  factory ReportData.fromJson(Map<String, dynamic> json) {
    return ReportData(
      startDate: DateTime.parse(_stringValue(json, 'start_date')),
      endDate: DateTime.parse(_stringValue(json, 'end_date')),
      locationId: _nullableStringValue(json, 'location_id'),
      locations: _listValue(json, 'locations')
          .map(
            (item) =>
                ReportLocation.fromJson(_mapValue(item, 'locations item')),
          )
          .toList(growable: false),
      totals: ReportTotals.fromJson(_mapValue(json['totals'], 'totals')),
      channelSplit: _listValue(json, 'channel_split')
          .map(
            (item) =>
                ReportChannel.fromJson(_mapValue(item, 'channel_split item')),
          )
          .toList(growable: false),
      revenueTrend: _listValue(json, 'revenue_trend')
          .map(
            (item) => ReportTrendPoint.fromJson(
              _mapValue(item, 'revenue_trend item'),
            ),
          )
          .toList(growable: false),
      locationPerformance: _listValue(json, 'location_performance')
          .map(
            (item) => ReportLocationPerformance.fromJson(
              _mapValue(item, 'location_performance item'),
            ),
          )
          .toList(growable: false),
    );
  }
}

class ReportLocation {
  const ReportLocation({required this.id, required this.name});

  final String id;
  final String name;

  factory ReportLocation.fromJson(Map<String, dynamic> json) {
    return ReportLocation(
      id: _stringValue(json, 'id'),
      name: _stringValue(json, 'name'),
    );
  }
}

class ReportTotals {
  const ReportTotals({
    required this.currencyCode,
    required this.revenueTotalMinor,
    required this.orderTotal,
    required this.averageTicketMinor,
  });

  final String? currencyCode;
  final int revenueTotalMinor;
  final int orderTotal;
  final int averageTicketMinor;

  factory ReportTotals.fromJson(Map<String, dynamic> json) {
    return ReportTotals(
      currencyCode: _nullableStringValue(json, 'currency_code'),
      revenueTotalMinor: _intValue(json, 'revenue_total_minor'),
      orderTotal: _intValue(json, 'order_total'),
      averageTicketMinor: _intValue(json, 'average_ticket_minor'),
    );
  }
}

class ReportChannel {
  const ReportChannel({
    required this.channel,
    required this.label,
    required this.revenueMinor,
    required this.orderTotal,
    required this.revenuePercent,
  });

  final String channel;
  final String label;
  final int revenueMinor;
  final int orderTotal;
  final double revenuePercent;

  factory ReportChannel.fromJson(Map<String, dynamic> json) {
    return ReportChannel(
      channel: _stringValue(json, 'channel'),
      label: _stringValue(json, 'label'),
      revenueMinor: _intValue(json, 'revenue_minor'),
      orderTotal: _intValue(json, 'order_total'),
      revenuePercent: _doubleValue(json, 'revenue_percent'),
    );
  }
}

class ReportTrendPoint {
  const ReportTrendPoint({
    required this.date,
    required this.revenueMinor,
    required this.orderTotal,
  });

  final DateTime date;
  final int revenueMinor;
  final int orderTotal;

  factory ReportTrendPoint.fromJson(Map<String, dynamic> json) {
    return ReportTrendPoint(
      date: DateTime.parse(_stringValue(json, 'date')),
      revenueMinor: _intValue(json, 'revenue_minor'),
      orderTotal: _intValue(json, 'order_total'),
    );
  }
}

class ReportLocationPerformance {
  const ReportLocationPerformance({
    required this.locationId,
    required this.locationName,
    required this.currencyCode,
    required this.revenueMinor,
    required this.orderTotal,
    required this.averageTicketMinor,
    required this.revenueGrowthPercent,
  });

  final String locationId;
  final String locationName;
  final String currencyCode;
  final int revenueMinor;
  final int orderTotal;
  final int averageTicketMinor;
  final double? revenueGrowthPercent;

  factory ReportLocationPerformance.fromJson(Map<String, dynamic> json) {
    return ReportLocationPerformance(
      locationId: _stringValue(json, 'location_id'),
      locationName: _stringValue(json, 'location_name'),
      currencyCode: _stringValue(json, 'currency_code'),
      revenueMinor: _intValue(json, 'revenue_minor'),
      orderTotal: _intValue(json, 'order_total'),
      averageTicketMinor: _intValue(json, 'average_ticket_minor'),
      revenueGrowthPercent: _nullableDoubleValue(
        json,
        'revenue_growth_percent',
      ),
    );
  }
}

Map<String, dynamic> _mapValue(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Invalid $field response.');
}

List<dynamic> _listValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is List) return value;
  throw FormatException('Invalid $field response.');
}

String _stringValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Invalid $field response.');
}

String? _nullableStringValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Invalid $field response.');
}

int _intValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is num) return value.toInt();
  throw FormatException('Invalid $field response.');
}

double _doubleValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is num) return value.toDouble();
  throw FormatException('Invalid $field response.');
}

double? _nullableDoubleValue(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw FormatException('Invalid $field response.');
}
