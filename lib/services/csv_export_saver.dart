import 'package:file_picker/file_picker.dart';

import 'report_service.dart';

abstract interface class CsvExportSaver {
  Future<void> save(ReportExport export);
}

class FilePickerCsvExportSaver implements CsvExportSaver {
  const FilePickerCsvExportSaver();

  @override
  Future<void> save(ReportExport export) async {
    await FilePicker.platform.saveFile(
      dialogTitle: 'Save report CSV',
      fileName: export.filename,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      bytes: export.bytes,
      lockParentWindow: true,
    );
  }
}
