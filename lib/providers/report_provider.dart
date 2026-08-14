import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/report_data.dart';
import '../services/csv_export_saver.dart';
import '../services/pdf_export_saver.dart';
import '../services/report_service.dart';
import 'auth_provider.dart';
import 'workspace_provider.dart';

enum ReportPeriod { last7Days, last30Days, thisQuarter }

class ReportFilter {
  const ReportFilter({
    required this.period,
    required this.startDate,
    required this.endDate,
    this.locationId,
    this.locationName,
  });

  final ReportPeriod period;
  final DateTime startDate;
  final DateTime endDate;
  final String? locationId;
  final String? locationName;

  factory ReportFilter.forPeriod(ReportPeriod period, DateTime today) {
    final endDate = DateTime(today.year, today.month, today.day);
    final startDate = switch (period) {
      ReportPeriod.last7Days => endDate.subtract(const Duration(days: 6)),
      ReportPeriod.last30Days => endDate.subtract(const Duration(days: 29)),
      ReportPeriod.thisQuarter => DateTime(
        endDate.year,
        ((endDate.month - 1) ~/ 3) * 3 + 1,
      ),
    };
    return ReportFilter(period: period, startDate: startDate, endDate: endDate);
  }

  ReportFilter withPeriod(ReportPeriod value, DateTime today) {
    final range = ReportFilter.forPeriod(value, today);
    return ReportFilter(
      period: value,
      startDate: range.startDate,
      endDate: range.endDate,
      locationId: locationId,
      locationName: locationName,
    );
  }

  ReportFilter withLocation(ReportLocation? location) {
    return ReportFilter(
      period: period,
      startDate: startDate,
      endDate: endDate,
      locationId: location?.id,
      locationName: location?.name,
    );
  }
}

final reportTodayProvider = Provider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

final reportFilterProvider = StateProvider.autoDispose<ReportFilter>((ref) {
  return ReportFilter.forPeriod(
    ReportPeriod.last30Days,
    ref.watch(reportTodayProvider),
  );
});

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService(ref.watch(apiClientProvider));
});

final effectiveReportFilterProvider = Provider.autoDispose<ReportFilter>((ref) {
  final filter = ref.watch(reportFilterProvider);
  final workspace = ref.watch(workspaceProvider).activeWorkspace;
  if (filter.locationId == null ||
      workspace?.locationById(filter.locationId) != null) {
    return filter;
  }
  return filter.withLocation(null);
});

final reportProvider = FutureProvider.autoDispose<ReportData>((ref) {
  final filter = ref.watch(effectiveReportFilterProvider);
  final workspace = ref.watch(workspaceProvider).activeWorkspace;
  if (workspace == null) {
    throw StateError('Workspace context is required.');
  }
  return ref
      .watch(reportServiceProvider)
      .fetch(
        startDate: filter.startDate,
        endDate: filter.endDate,
        workspaceId: workspace.id,
        locationId: filter.locationId,
      );
});

final csvExportSaverProvider = Provider<CsvExportSaver>((ref) {
  return const FilePickerCsvExportSaver();
});

final pdfExportSaverProvider = Provider<PdfExportSaver>((ref) {
  return const FilePickerPdfExportSaver();
});
